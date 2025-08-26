const std = @import("std");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var exit_code: u8 = undefined;

    _ = try runCmd(arena_allocator, &.{ "git", "diff" }, &exit_code);
    if (exit_code != 0) {
        std.debug.print("uncommitted changes, aborting", .{});
        return;
    }

    var patch_names = std.array_list.Managed([]const u8).init(arena_allocator);
    var patch_dir = try std.fs.cwd().openDir("patch", .{ .iterate = true });
    defer patch_dir.close();
    var dir_iter = patch_dir.iterate();
    while (try dir_iter.next()) |d| {
        try patch_names.append(d.name);
    }
    std.debug.print("found {} patches:", .{patch_names.items.len});
    for (patch_names.items) |n| std.debug.print(" {s}", .{n});
    std.debug.print("\n", .{});

    for (patch_names.items) |patch_name| {
        std.debug.print("applying patch {s}\n", .{patch_name});
        try gitReset(arena_allocator);
        try applyPatch(arena_allocator, patch_name);
        try runTest(arena_allocator);
    }

    try gitReset(arena_allocator);
}

fn runCmd(
    allocator: std.mem.Allocator,
    cmd: []const []const u8,
    exit_code: ?*u8,
) ![]const u8 {
    std.debug.print("running command:", .{});
    for (cmd) |c| std.debug.print(" {s}", .{c});
    std.debug.print("\n", .{});

    var child = std.process.Child.init(cmd, allocator);
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    const res = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));

    const code = (try child.wait()).Exited;
    if (exit_code) |c| c.* = code;

    return res;
}

fn gitReset(arena: std.mem.Allocator) !void {
    _ = try runCmd(arena, &.{ "git", "reset", "--hard" }, null);
}

fn applyPatch(arena: std.mem.Allocator, patch_name: []const u8) !void {
    var exit_code: u8 = undefined;
    const patch_path = try std.fmt.allocPrint(arena, "patch/{s}/{s}.diff", .{ patch_name, patch_name });
    _ = try runCmd(arena, &.{ "git", "apply", patch_path }, &exit_code);
    if (exit_code != 0) {
        std.debug.print("git apply failed, exit code {}", .{exit_code});
        return;
    }
}

fn runTest(arena: std.mem.Allocator) !void {
    var exit_code: u8 = undefined;
    _ = try runCmd(arena, &.{ "zig", "build", "test", "--summary", "all" }, &exit_code);
    if (exit_code != 0) {
        std.debug.print("zig test failed, exit code {}", .{exit_code});
        return;
    }
}
