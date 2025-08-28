const std = @import("std");
const core = @import("core.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    for (try core.findPatches(arena_allocator)) |patch| {
        const out = try core.runCmd(arena_allocator, &.{ "git", "diff", "master", patch, "--", "src" }, null);
        const patch_path = try std.fmt.allocPrint(arena_allocator, "patch/{s}/{s}.diff", .{ patch, patch });
        const f = try std.fs.cwd().createFile(patch_path, .{ .truncate = true });
        std.debug.print("writing patch to: {s}\n", .{patch_path});
        try f.writeAll(out);
    }
}
