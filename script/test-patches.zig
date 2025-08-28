const std = @import("std");
const core = @import("core.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var exit_code: u8 = undefined;

    _ = try core.runCmd(arena_allocator, &.{ "git", "diff" }, &exit_code);
    if (exit_code != 0) {
        std.debug.print("uncommitted changes, aborting", .{});
        return error.UncommittedChanges;
    }

    const patch_names = try core.findPatches(arena_allocator);
    for (patch_names) |patch_name| {
        std.debug.print("applying patch {s}\n", .{patch_name});
        try gitReset(arena_allocator);
        try applyPatch(arena_allocator, patch_name);
        try runTest(arena_allocator);
    }

    try gitReset(arena_allocator);
}

fn gitReset(arena: std.mem.Allocator) !void {
    _ = try core.runCmd(arena, &.{ "git", "reset", "--hard" }, null);
}

fn applyPatch(arena: std.mem.Allocator, patch_name: []const u8) !void {
    var exit_code: u8 = undefined;
    const patch_path = try std.fmt.allocPrint(arena, "patch/{s}/{s}.diff", .{ patch_name, patch_name });
    _ = try core.runCmd(arena, &.{ "git", "apply", patch_path }, &exit_code);
    if (exit_code != 0) {
        std.debug.print("git apply failed, exit code {}\n", .{exit_code});
        return error.Apply;
    }
}

fn runTest(arena: std.mem.Allocator) !void {
    var exit_code: u8 = undefined;
    _ = try core.runCmd(arena, &.{ "zig", "build", "test", "--summary", "all" }, &exit_code);
    if (exit_code != 0) {
        std.debug.print("zig test failed, exit code {}\n", .{exit_code});
        return error.Test;
    }
}
