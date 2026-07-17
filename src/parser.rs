//! Provisioning and invoking Google's GoogleSQL parser via Docker.
//!
//! The language server does not depend on `execute_query` being installed on the
//! host. On first use it provisions the parser itself: it downloads the latest
//! GoogleSQL Docker image tarball from GitHub releases, loads it, runs it as a
//! long-lived container, and then calls `execute_query --mode=parse` inside that
//! container for each parse. This works on macOS, Linux, and Windows wherever
//! Docker is available.
//!
//! `execute_query` prints parse errors to stdout with an `... [at L:C]` suffix and
//! exits 0 even on a syntax error, so a non-zero exit from `docker exec` reliably
//! means the container/Docker is unhealthy rather than a parse failure.

use std::path::Path;
use std::process::Command;

use regex::Regex;

/// The release tarball loads as `googlesql_ubuntu:latest`; we re-tag it per version.
const IMAGE: &str = "googlesql_ubuntu";
/// Name of the long-lived helper container we exec into.
const CONTAINER: &str = "googlesql-lsp"; //TODO Consider another name
/// Path of the parser binary inside the image.
const EXEC_PATH: &str = "/googlesql/execute_query";
/// Release asset holding the Docker image.
const TARBALL: &str = "googlesql_docker.tar.gz";
/// GitHub API endpoint for the newest published release.
const RELEASES_API: &str = "https://api.github.com/repos/google/googlesql/releases/latest";
/// GitHub requires a User-Agent on API requests.
const USER_AGENT: &str = "googlesql-lsp";

/// A ready-to-use parser backend. Modeled as an enum so a `Native(PathBuf)` fast
/// path can be added later without changing callers.
#[derive(Clone)]
pub enum Parser {
    Docker { image: String },
}

/// A user-facing reason bootstrapping failed; surfaced verbatim as an LSP message.
pub struct InitError {
    pub message: String,
}

//TODO Should init and run_parse be methods of Parser?

/// First-run provisioning: verify Docker is usable, resolve the parser version,
/// ensure its image is loaded, and ensure the helper container is running.
///
/// Blocking (spawns `docker` and may download a large tarball) — call from a
/// blocking context, not directly on the async runtime.
pub fn init() -> Result<Parser, InitError> {
    if !docker_available() {
        return Err(InitError {
            message: "googlesql-lsp: Docker is required but was not found on PATH. \
                      Install Docker Desktop (macOS/Windows) or the docker engine (Linux), \
                      then reopen the file.".to_string(),
        });
    }
    if !docker_daemon_up() {
        return Err(InitError {
            message: "googlesql-lsp: the Docker daemon is not running. Start Docker Desktop \
                      (or the docker service) and reopen the file.".to_string(),
        });
    }

    let image = match resolve_version() {
        Some(version) => ensure_image(&version).map_err(|e| InitError {
            message: format!("googlesql-lsp: could not provision the GoogleSQL parser image: {e}"),
        })?,
        // Offline or GitHub rate-limited: reuse an image left by a prior install.
        None => any_existing_image().ok_or_else(|| InitError {
            //TODO Will be more specific if resolve_version returns Result
            message: "googlesql-lsp: could not resolve the latest GoogleSQL release (offline \
                      or GitHub rate limit) and no previously downloaded image was found. Set \
                      $GOOGLESQL_VERSION or retry with a network connection.".to_string(),
        })?,
    };

    ensure_container(&image).map_err(|e| InitError {
        message: format!("googlesql-lsp: could not start the parser container: {e}"),
    })?;

    Ok(Parser::Docker { image })
}

/// Run `execute_query --mode=parse <sql>` and return its combined stdout+stderr.
///
/// The SQL is passed as a single argv element (no shell), so no escaping is needed.
/// `Err` means Docker/the container failed — not a parse result — so the caller can
/// avoid feeding Docker's own error text to the diagnostics scraper.
pub fn run_parse(parser: &Parser, sql: &str) -> std::io::Result<String> {
    match parser {
        Parser::Docker { image } => docker_parse(image, sql),
    }
}

// --- Docker invocation --------------------------------------------------------

fn docker_parse(image: &str, sql: &str) -> std::io::Result<String> {
    // Hot path: a single `docker exec`. execute_query exits 0 even on syntax
    // errors, so a non-zero exit means the container isn't up.
    let output = exec_parse(sql)?;
    if let Some(text) = parser_output(&output) {
        return Ok(text);
    }

    // (Re)start the container and retry once.
    let _ = ensure_container(image);
    let output = exec_parse(sql)?;
    if let Some(text) = parser_output(&output) {
        return Ok(text);
    }

    Err(std::io::Error::other(format!(
        "docker exec failed: {}",
        String::from_utf8_lossy(&output.stderr).trim()
    )))
}

fn exec_parse(sql: &str) -> std::io::Result<std::process::Output> {
    Command::new("docker")
        .args(["exec", CONTAINER, EXEC_PATH, "--mode=parse"])
        .arg(sql)
        .output()
}

/// Combined stdout+stderr of a successful parser run, or `None` if `docker exec`
/// itself failed (container down / Docker error).
fn parser_output(output: &std::process::Output) -> Option<String> {
    if !output.status.success() {
        return None;
    }
    let mut combined = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !stderr.is_empty() {
        combined.push_str(&stderr);
    }
    Some(combined)
}

// --- Provisioning helpers -----------------------------------------------------

fn docker_available() -> bool {
    docker_ok(&["--version"])
}

fn docker_daemon_up() -> bool {
    docker_ok(&["info"])
}

/// Run `docker <args>` and report whether it exited successfully.
fn docker_ok(args: &[&str]) -> bool {
    Command::new("docker")
        .args(args)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Resolve the parser version: `$GOOGLESQL_VERSION` if set, else the latest release
/// tag from the GitHub API. Returns `None` when neither is available.
fn resolve_version() -> Option<String> { //TODO Return `Result` to be able to debug errors?
    if let Ok(v) = std::env::var("GOOGLESQL_VERSION") {
        let v = v.trim();
        if !v.is_empty() {
            return Some(v.to_string());
        }
    }

    let body = ureq::get(RELEASES_API)
        .set("User-Agent", USER_AGENT)
        .call()
        .ok()?
        .into_string()
        .ok()?;

    // Extract just the tag; avoids pulling in a JSON parser for one field.
    let re = Regex::new(r#""tag_name"\s*:\s*"([^"]+)""#).ok()?;
    re.captures(&body)
        .map(|caps| caps[1].to_string())
        .filter(|tag| !tag.is_empty())
}

/// Ensure `googlesql_ubuntu:<version>` is loaded; download and load it if not.
/// Returns the image reference to run.
fn ensure_image(version: &str) -> Result<String, String> {
    let image = format!("{IMAGE}:{version}");
    if image_exists(&image) {
        return Ok(image);
    }

    let tarball = std::env::temp_dir().join(TARBALL);
    download_tarball(version, &tarball)?;

    let load = Command::new("docker")
        .arg("load")
        .arg("-i")
        .arg(&tarball)
        .output()
        .map_err(|e| format!("running `docker load`: {e}"))?;
    let _ = std::fs::remove_file(&tarball);
    if !load.status.success() {
        return Err(format!(
            "`docker load` failed: {}",
            String::from_utf8_lossy(&load.stderr).trim()
        ));
    }

    // The tarball loads as googlesql_ubuntu:latest; pin it to this version so we
    // reference an exact tag rather than a moving :latest on later runs.
    let latest = format!("{IMAGE}:latest");
    let _ = Command::new("docker")
        .args(["tag", &latest, &image])
        .output();

    if image_exists(&image) {
        Ok(image)
    } else if image_exists(&latest) { //TODO No expected image -> should be an error?
        // Tarball loaded under an unexpected tag; run whatever landed.
        Ok(latest)
    } else {
        Err("image did not load under the expected name".to_string())
    }
}

fn image_exists(image: &str) -> bool {
    docker_ok(&["image", "inspect", image])
}

/// Newest locally loaded `googlesql_ubuntu` image, if any — the offline fallback.
fn any_existing_image() -> Option<String> {
    let out = Command::new("docker")
        .args(["images", "--format", "{{.Repository}}:{{.Tag}}", IMAGE])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.ends_with(":<none>"))
        .map(str::to_string)
}

fn download_tarball(version: &str, dest: &Path) -> Result<(), String> {
    //TODO Use releases URL constant
    let url = format!("https://github.com/google/googlesql/releases/download/{version}/{TARBALL}");
    let resp = ureq::get(&url)
        .set("User-Agent", USER_AGENT)
        .call()
        .map_err(|e| format!("downloading {url}: {e}"))?;

    let mut reader = resp.into_reader();
    let mut file = std::fs::File::create(dest)
        .map_err(|e| format!("creating {}: {e}", dest.display()))?;
    std::io::copy(&mut reader, &mut file).map_err(|e| format!("writing image tarball: {e}"))?;
    Ok(())
}

/// Ensure the helper container is running against `image`, (re)creating it if not.
fn ensure_container(image: &str) -> Result<(), String> {
    //TODO Passing image as param, but checking container using global var - code smell?
    if container_running() {
        return Ok(());
    }

    // Drop any stale container (stopped, or built from a previous image).
    //TODO Do we need to handle an error
    let _ = Command::new("docker").args(["rm", "-f", CONTAINER]).output();

    let mut cmd = Command::new("docker");
    cmd.args(["run", "-d", "--name", CONTAINER, "--entrypoint", "sleep"]);
    if needs_amd64_platform() {
        // The image is linux/amd64; Apple Silicon needs an explicit platform.
        cmd.args(["--platform", "linux/amd64"]);
    }
    cmd.arg(image).arg("infinity"); // infinity is arg to sleep

    // Err means OS failed to execute `docker run` in a subprocess
    // (e.g. no `docker`, no permissions)
    let out = cmd
        .output()
        .map_err(|e| format!("running `docker run`: {e}"))?;
    // `docker run` executed, but returned non-zero code (e.g. bad image)
    if !out.status.success() {
        return Err(format!(
            "`docker run` failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

fn container_running() -> bool {
    Command::new("docker")
        .args(["inspect", "-f", "{{.State.Running}}", CONTAINER])
        .output()
        .map(|o| o.status.success() && String::from_utf8_lossy(&o.stdout).trim() == "true")
        .unwrap_or(false)
}

fn needs_amd64_platform() -> bool {
    cfg!(target_os = "macos") && cfg!(target_arch = "aarch64")
}
