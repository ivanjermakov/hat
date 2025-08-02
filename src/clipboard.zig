const std = @import("std");
const log = @import("log.zig");

const Allocator = std.mem.Allocator;

pub fn write(allocator: Allocator, text: []const u8) !void {
    log.log(@This(), "copy to clipboard\n", .{});
    var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard" }, allocator);
    child.stdin_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    try child.stdin.?.writeAll(text);
    child.stdin.?.close();
    child.stdin = null;
    const code = (try child.wait()).Exited;
    if (code != 0) return error.Xclip;
}

pub fn read(allocator: Allocator) ![]const u8 {
    log.log(@This(), "read from clipboard\n", .{});
    var child = std.process.Child.init(&.{ "xclip", "-selection", "clipboard", "-o" }, allocator);
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    const res = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    const code = (try child.wait()).Exited;
    if (code != 0) return error.Xclip;

    return res;
}
