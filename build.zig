const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    const lsp_kit = b.dependency("lsp_kit", .{});
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit.module("lsp") },
            // Uncomment along with removing translate_c_to_zig below
            // .{ .name = "c", .module = translate_c.createModule() },
        },
    });
    const parser_dep = switch (target.result.os.tag) {
        .macos => switch (target.result.cpu.arch) {
            .x86_64 => "googlesql_parser-macos_x86_64",
            .aarch64 => "googlesql_parser-macos_arm64",
            else => @panic("Unsupported target architecture"),
        },
        .linux => switch (target.result.cpu.arch) {
            .x86_64 => "googlesql_parser-linux_x86_64",
            .aarch64 => "googlesql_parser-linux_aarch64",
            else => @panic("Unsupported target architecture"),
        },
        else => @panic("Unsupported target OS"),
    };
    if (b.dependencyLazy(parser_dep, .{})) |dep| {
        root_module.addObjectFile(dep.path("lib/libgooglesql_parser.a"));
        translate_c.addIncludePath(dep.path("include"));
    } else |_| { // the toolchain will fetch the dependency and re-run build
        return;
    }
    // GoogleSql uses Abseil library. And Abseil's time zone lookup calls CoreFoundation on macOS,
    // which is not shipped with the lib.
    if (target.result.os.tag.isDarwin()) root_module.linkFramework("CoreFoundation", .{});
    const exe = b.addExecutable(.{
        .name = "googlesql_lsp",
        .root_module = root_module,
    });

    // ZLS can't use zig build yet (zigtools/zls#3208) to resolve c.h and include/googlesql_parser.h,
    // so we manually store the output of TranslateC to src/c.zig to enable completions in the editor.
    // Remove once ZLS can work with c.h directly
    const translate_c_to_zig = b.addUpdateSourceFiles();
    translate_c_to_zig.addCopyFileToSource(translate_c.getOutput(), "src/c.zig");
    exe.step.dependOn(&translate_c_to_zig.step);

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const install_tests = b.addInstallArtifact(tests, .{});
    const run_tests = b.addRunArtifact(tests);
    const tests_step = b.step("test", "Run tests");
    tests_step.dependOn(&run_tests.step);
    tests_step.dependOn(&install_tests.step);

    tests_step.dependOn(&translate_c_to_zig.step);
}
