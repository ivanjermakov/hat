const std = @import("std");

const patches = .{
    "git-signs",
    "ts-symbol-picker",
    "buffer-centering",
    "autosave",
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    inline for (patches) |patch| {
        const out = try runCmd(allocator, &.{ "git", "diff", patch, "master" });
        defer allocator.free(out);
        const patch_path = std.fmt.comptimePrint("patch/{s}/{s}.diff", .{ patch, patch });
        const f = try std.fs.cwd().createFile(patch_path, .{ .truncate = true });
        std.debug.print("writing patch to: {s}\n", .{patch_path});
        try f.writeAll(out);
    }
}

fn runCmd(
    allocator: std.mem.Allocator,
    cmd: []const []const u8,
) ![]const u8 {
    std.debug.print("running command:", .{});
    for (cmd) |c| std.debug.print(" {s}", .{c});
    std.debug.print("\n", .{});

    var child = std.process.Child.init(cmd, allocator);
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    return try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
}
