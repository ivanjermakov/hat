const std = @import("std");
const main = @import("main.zig");
const log = @import("log.zig");

pub fn runExternalWait(allocator: std.mem.Allocator, cmd: []const []const u8, input: ?[]const u8) ![]const u8 {
    if (log.enabled) {
        log.debug(@This(), "running external command:", .{});
        for (cmd) |c| std.debug.print(" \"{s}\"", .{c});
        std.debug.print("\n", .{});
    }
    var child = std.process.Child.init(cmd, allocator);
    if (input != null) child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    if (input) |inp| {
        try child.stdin.?.writeAll(inp);
        child.stdin.?.close();
        child.stdin = null;
    }

    const res = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    try main.term.switchBuf(true);

    const code = (try child.wait()).Exited;
    log.debug(@This(), "external command exit code: {}\n", .{code});
    main.editor.dirty.draw = true;

    return res;
}
