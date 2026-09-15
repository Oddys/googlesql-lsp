const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.addIncludePath(b.path("include"));
    // ZLS can't use zig build yet (zigtools/zls#3208) to resolve c.h and include/googlesql_parser.h,
    // so we manually store the output of TranslateC to src/c.zig to enable completions in the editor.
    const translate_c_to_zig = b.addUpdateSourceFiles();
    translate_c_to_zig.addCopyFileToSource(translate_c.getOutput(), "src/c.zig");

    const lsp_kit = b.dependency("lsp_kit", .{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "lsp", .module = lsp_kit.module("lsp") },
        },
    });
    root_module.addObjectFile(b.path("lib/libgooglesql_parser.a"));
    // GoogleSql uses Abseil library. And Abseil's time zone lookup calls CoreFoundation on macOS,
    // which is not shipped with the lib.
    if (target.result.os.tag.isDarwin()) root_module.linkFramework("CoreFoundation", .{});

    const exe = b.addExecutable(.{
        .name = "googlesql_lsp",
        .root_module = root_module,
    });

    // Remove once ZLS can work with c.h directly
    exe.step.dependOn(&translate_c_to_zig.step);

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
}
