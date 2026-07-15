# Can this extension work for Zed users on Windows?

`execute_query` is published by Google for **macOS and Linux only**
(https://github.com/google/googlesql/releases). This note explains what that
means for Windows support.

## The server code itself is portable

The Rust server would *compile and run* on Windows fine. Notably,
`src/parser.rs:41` uses `std::env::split_paths`, which correctly handles Windows'
`;`-separated `PATH`, and everything else is cross-platform Rust. The
`~/.local/share/...` default path (`parser.rs:8`) is unconventional on Windows
but harmless (it's just a path join). So portability of *our* code is not the
wall.

## The hard blocker

The whole architecture rests on shelling out to `execute_query --mode=parse`
(`src/parser.rs:56`). That binary is a **native compiled executable**, published
only for macOS and Linux. A native Windows Zed process cannot run a Linux ELF or a
macOS Mach-O binary — there's no shim, no compatibility layer. So on native
Windows there is simply nothing for the server to invoke.

The options for producing a Windows-native `execute_query` are all dead ends:

- **Build it ourselves** — GoogleSQL is a giant Bazel/C++ tree whose *macOS*
  support Google itself labels "experimental," with no Windows build target. The
  README's whole reason-for-being is avoiding that build. Not viable.
- **Compile the parser to WASM/WASI** — Google doesn't ship this, and porting the
  C++ to WASI is a research project, not a config change.
- **Hosted parsing service** — send the user's SQL to a Linux box running
  `execute_query`. Technically works, but it puts users' SQL on the network
  (privacy) and adds a service we must run. Contradicts the "no server, no Docker"
  pitch.

## The one realistic route: WSL2

Windows users who want this can go through the **Windows Subsystem for Linux**, in
two flavors:

**(a) Run Zed itself inside WSL2 (cleanest, works today).** If the user runs a
Linux build of Zed under WSL2, then from the extension's perspective *it's just
Linux*. The Linux `execute_query` binary runs natively, the server runs natively,
and **no Windows-specific code is needed** — the same download-from-releases logic
we'd add for Linux just works. The "Windows support" we offer is really "install
it in WSL," documented in the README. Lead with this.

**(b) Native Windows Zed shelling out through `wsl.exe` (real work, fragile).**
Keep Zed on Windows but have the server, when it detects Windows, invoke the Linux
binary via `wsl.exe execute_query --mode=parse ...` instead of running it
directly. Doable, but it carries real cost:

- The user must have WSL2 installed with a distro **and** the Linux
  `execute_query` placed inside that distro.
- We must translate paths across the Windows↔WSL boundary and spawn `wsl.exe` on
  every debounced parse (`src/parser.rs:55`), adding per-keystroke latency on top
  of the process spawn we already pay.
- More moving parts to break and support.

Only build (b) if there's real demand; (a) gets Windows-via-WSL users working with
essentially no new code.

## Two other things worth knowing

- **Zed on Windows is itself young.** Zed's Windows support has historically
  lagged macOS/Linux. Before investing in Windows packaging, confirm the current
  state of native Zed-for-Windows — if most would-be Windows users are on WSL
  anyway, option (a) covers them and (b) may never be worth it.
- **Fail gracefully, don't fail silently.** However we handle it, when the server
  starts on native Windows with no reachable parser, surface a clear diagnostic —
  the existing message at `src/backend.rs:123` should gain a Windows-specific
  branch pointing users to WSL, rather than the generic "run install-parser.sh."

## Bottom line

We can't give **native** Windows users error highlighting without a Windows
`execute_query`, which doesn't exist and isn't practical to produce. What we *can*
do — and should document as the Windows story — is support them through **WSL2**,
ideally by having them run Zed inside WSL (no code changes), with an optional
`wsl.exe`-bridge mode later if native-Windows-Zed demand justifies it.
