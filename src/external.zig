const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const log = @import("log.zig");
const main = @import("main.zig");

pub const RunOptions = struct {
    input: ?[]const u8 = null,
    exit_code: ?*u8 = null,
    stderr_behavior: std.process.Child.StdIo = .Pipe,
};

pub fn runExternalWait(
    allocator: Allocator,
    cmd: []const []const u8,
    opts: RunOptions,
) ![]const u8 {
    if (log.enabled(.debug)) {
        log.debug(@This(), "running command:", .{});
        for (cmd) |c| log.errPrint(" \"{s}\"", .{c});
        log.errPrint("\n", .{});
    }
    var child = std.process.Child.init(cmd, allocator);
    if (opts.input != null) child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = opts.stderr_behavior;

    try child.spawn();
    try child.waitForSpawn();

    if (opts.input) |inp| {
        log.debug(@This(), "writing stdin: {s}\n", .{inp});
        try child.stdin.?.writeAll(inp);
        child.stdin.?.close();
        child.stdin = null;
    }

    const res = try child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));

    if (opts.stderr_behavior == .Pipe) {
        const err = try child.stderr.?.readToEndAlloc(allocator, std.math.maxInt(usize));
        if (err.len > 0) {
            log.debug(@This(), "command stderr:\n{s}\n", .{err});
        }
    }

    try main.term.switchBuf(true);

    const code = (try child.wait()).Exited;
    log.debug(@This(), "command exit code: {}\n", .{code});
    if (opts.exit_code) |c| c.* = code;
    main.editor.dirty.draw = true;

    return res;
}

pub fn toArgv(allocator: Allocator, cmd: []const u8) ![]const []const u8 {
    var parts: std.array_list.Aligned([]const u8, null) = .empty;

    var start: usize = 0;
    var quoted: bool = false;

    for (cmd, 0..) |c, i| {
        if (c == '"') {
            if (quoted) {
                try parts.append(allocator, cmd[start..i]);
                start = i + 1;
            } else {
                start = i + 1;
            }
            quoted = !quoted;
            continue;
        }
        if (c == ' ' and !quoted) {
            try parts.append(allocator, cmd[start..i]);
            start = i + 1;
        }
    }
    if (start < cmd.len) {
        try parts.append(allocator, cmd[start..]);
    }

    return parts.toOwnedSlice(allocator);
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
