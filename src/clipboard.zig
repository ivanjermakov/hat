const std = @import("std");
const log = @import("log.zig");

pub fn write(allocator: std.mem.Allocator, text: []const u8) !void {
    log.log(@This(), "copy to clipboard\n", .{});
    var child = std.process.Child.init(&.{"xclip", "-selection", "clipboard"}, allocator);
    child.stdin_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    try child.stdin.?.writeAll(text);
    child.stdin.?.close();
    child.stdin = null;
    const code = (try child.wait()).Exited;
    if (code != 0) return error.Xclip;
}
