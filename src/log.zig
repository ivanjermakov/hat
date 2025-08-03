const std = @import("std");
const main = @import("main.zig");
const dt = @import("datetime.zig");
const co = @import("color.zig");

pub var enabled = false;
pub var level: Level = .debug;

const Level = enum(u8) {
    err = 0,
    warn,
    info,
    debug,

    fn ansi(self: Level) co.AnsiColor {
        return switch (self) {
            .err => .red,
            .warn => .yellow,
            .info => .blue,
            .debug => .bright_black,
        };
    }

    pub fn format(
        self: Level,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{}", .{self.ansi()});
        try switch (self) {
            .err => writer.writeAll("err"),
            .warn => writer.writeAll("wrn"),
            .info => writer.writeAll("inf"),
            .debug => writer.writeAll("dbg"),
        };
        try writer.writeAll(co.AnsiColor.reset);
    }
};

pub fn err(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    log(caller, .err, fmt, args);
}

pub fn warn(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    log(caller, .warn, fmt, args);
}

pub fn info(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    log(caller, .info, fmt, args);
}

pub fn debug(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    log(caller, .debug, fmt, args);
}

pub fn assertEql(comptime Caller: type, comptime T: type, actual: []const T, expected: []const T) void {
    if (!std.mem.eql(T, actual, expected)) {
        err(Caller, "assert failed:\n  actual: {any}\n  expected: {any}\n", .{ actual, expected });
        unreachable;
    }
}

fn log(comptime caller: type, comptime lvl: Level, comptime fmt: []const u8, args: anytype) void {
    if (!(enabled and @intFromEnum(lvl) <= @intFromEnum(level))) return;
    const writer = main.std_err.writer();

    var now_buf: [32]u8 = undefined;
    const now_str = dt.Datetime.now().formatISO8601Buf(&now_buf, false) catch "";

    std.fmt.format(
        writer,
        "{s} {} {}{s: <16}{s} ",
        .{ now_str, lvl, co.AnsiColor.magenta, callerName(caller), co.AnsiColor.reset },
    ) catch {};
    std.fmt.format(writer, fmt, args) catch {};
}

fn callerName(comptime caller: type) []const u8 {
    const caller_name_full = @typeName(caller);
    var caller_name_iter = std.mem.splitBackwardsScalar(u8, caller_name_full, '.');
    return caller_name_iter.next() orelse caller_name_full;
}
