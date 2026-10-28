const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lsp_kit = b.dependency("lsp_kit", .{});
    const translate_c = b.dependency("translate_c", .{});
    const Translator = @import("translate_c").Translator;
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit.module("lsp") },
            .{ .name = "c", .module = t.mod },
        },
    });
    const parser_dep = switch (target.result.os.tag) {
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "googlesql_ffi_macos_x86_64",
            .aarch64 => "googlesql_ffi_macos_arm64",
            else => @panic("Unsupported target architecture"),
        },
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "googlesql_ffi_linux_x86_64",
            .aarch64 => "googlesql_ffi_linux_aarch64",
            else => @panic("Unsupported target architecture"),
        },
        else => @panic("Unsupported target OS"),
    };

    // The path to a locally downloaded parser tarball could be provided
    if (b.option([]const u8, "gsql-tar", "Path to a local googlesql_ffi_<platform>.tar.gz")) |tar_path| {
        const untar = b.addSystemCommand(&.{ "tar", "-xzf" });
        // tar_path could be either absolute or local
        untar.addFileArg(.{ .cwd_relative = tar_path });
        // `--strip-components=1` drops the tarball's top-level directory
        // `-C` expects the output directory (added by addOutputDirectoryArg)
        untar.addArgs(&.{ "--strip-components=1", "-C" });
        const dir = untar.addOutputDirectoryArg("googlesql_ffi");
        root_module.addObjectFile(dir.path(b, "lib/libgooglesql_ffi.a"));
        t.addIncludePath(dir.path(b, "include"));
    } else if (b.dependencyLazy(parser_dep, .{})) |dep| {
        root_module.addObjectFile(dep.path("lib/libgooglesql_ffi.a"));
        t.addIncludePath(dep.path("include"));
    } else |_| { // the toolchain will fetch the dependency and re-run build
        return;
    }
    // GoogleSql uses Abseil library. And Abseil's time zone lookup calls CoreFoundation on macOS,
    // which is not shipped with the lib.
    if (target.result.os.tag.isDarwin()) root_module.linkFramework("CoreFoundation", .{});
    const exe = b.addExecutable(.{
        .name = std.fmt.allocPrint(
            b.allocator,
            "googlesql_lsp_{s}_{s}",
            .{ @tagName(target.result.os.tag), @tagName(target.result.cpu.arch) },
        ) catch @panic("Cannot define the binary name"),
        .root_module = root_module,
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Test the app");
    test_step.dependOn(&run_exe_tests.step);
}
