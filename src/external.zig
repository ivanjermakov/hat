const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const log = @import("log.zig");
const main = @import("main.zig");

pub fn runExternalWait(
    allocator: Allocator,
    cmd: []const []const u8,
    input: ?[]const u8,
    exit_code: ?*u8,
) ![]const u8 {
    if (log.enabled(.debug)) {
        log.debug(@This(), "running command:", .{});
        for (cmd) |c| std.debug.print(" \"{s}\"", .{c});
        std.debug.print("\n", .{});
    }
    var child = std.process.Child.init(cmd, allocator);
    if (input != null) child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    if (input) |inp| {
        log.debug(@This(), "writing stdin: {s}\n", .{inp});
        try child.stdin.?.writeAll(inp);
        child.stdin.?.close();
        child.stdin = null;
    }

    const res = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));
    try main.term.switchBuf(true);

    const code = (try child.wait()).Exited;
    log.debug(@This(), "command exit code: {}\n", .{code});
    if (exit_code) |c| c.* = code;
    main.editor.dirty.draw = true;

    return res;
}

pub fn toArgv(allocator: Allocator, cmd: []const u8) ![]const []const u8 {
    var parts = std.ArrayList([]const u8).init(allocator);

    var start: usize = 0;
    var quoted: bool = false;

    for (cmd, 0..) |c, i| {
        if (c == '"') {
            if (quoted) {
                try parts.append(cmd[start..i]);
                start = i + 1;
            } else {
                start = i + 1;
            }
            quoted = !quoted;
            continue;
        }
        if (c == ' ' and !quoted) {
            try parts.append(cmd[start..i]);
            start = i + 1;
        }
    }
    if (start < cmd.len) {
        try parts.append(cmd[start..]);
    }

    return parts.toOwnedSlice();
}

test "toArgv" {
    try toArgvTest("", &.{});
    try toArgvTest("foo", &.{"foo"});
    try toArgvTest("foo bar baz", &.{ "foo", "bar", "baz" });
    try toArgvTest("foo \"bar baz\"", &.{ "foo", "bar baz" });
}

fn toArgvTest(cmd: []const u8, expected: []const []const u8) !void {
    const res = try toArgv(testing.allocator, cmd);
    defer testing.allocator.free(res);
    try testing.expectEqualDeep(expected, res);
}
