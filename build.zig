const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module: every implementation in src/ is reachable from here.
    const mod = b.addModule("db_internals", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Demo executables. Each article gets its own `zig build run-*` step so
    // readers can reproduce the numbers in the post.
    const buffer_exe = b.addExecutable(.{
        .name = "buffer_manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/01-buffer-manager/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(buffer_exe);

    const run_buffer_step = b.step("run-buffer", "Run the buffer pool demo");
    const run_buffer_cmd = b.addRunArtifact(buffer_exe);
    run_buffer_step.dependOn(&run_buffer_cmd.step);
    run_buffer_cmd.step.dependOn(b.getInstallStep());

    // Tests: `zig build test`.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
