const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // 默认使用 ReleaseSmall 优化级别（通过设置 b.release_mode = .small）
    b.release_mode = .small;
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // 启用 strip 将剥离符号，通常能够显著减小二进制体积
        .strip = true,
    });

    const exe = b.addExecutable(.{
        .name = "aaa",
        .root_module = exe_module,
    });

    // 安装可执行文件（用于 `zig build install` 等）
    b.installArtifact(exe);

    // 支持 `zig build run`
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
