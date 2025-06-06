const std = @import("std");

fn linkLibs(compile: *std.Build.Step.Compile) void {
    compile.linkLibC();
    compile.linkSystemLibrary("tree-sitter");
    compile.linkSystemLibrary("ncurses");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "hat",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkLibs(exe);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run.addArgs(args);
    }
    const run_step = b.step("run", "");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "");
    test_step.dependOn(&run_tests.step);

    const check_exe = b.addExecutable(.{
        .name = "hat",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });
    linkLibs(check_exe);
    const check_step = b.step("check", "");
    check_step.dependOn(&check_exe.step);
}
