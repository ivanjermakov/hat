const std = @import("std");

fn linkLibs(b: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.linkLibC();
    compile.linkSystemLibrary("tree-sitter");

    const lsp_kit = b.dependency("lsp_kit", .{});
    compile.root_module.addImport("lsp", lsp_kit.module("lsp"));

    const regex = b.dependency("pcrez", .{});
    compile.root_module.addImport("regex", regex.module("pcrez"));
}

pub fn build(b: *std.Build) void {
    b.reference_trace = 10;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ .name = "hat", .root_module = root_module });
    linkLibs(b, exe);
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run.addArgs(args);
    }
    const run_step = b.step("run", "");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root_module });
    linkLibs(b, tests);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "");
    test_step.dependOn(&run_tests.step);

    const check_step = b.step("check", "");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&tests.step);

    const cov_tests = b.addTest(.{ .root_module = root_module });
    linkLibs(b, cov_tests);
    cov_tests.use_llvm = true;
    cov_tests.setExecCmd(&.{ "kcov", "--include-path=src/", b.pathJoin(&.{ b.install_path, "kcov" }), null });
    const run_cov = b.addRunArtifact(cov_tests);
    const cov_step = b.step("coverage", "");
    cov_step.dependOn(&run_cov.step);
}
