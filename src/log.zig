const std = @import("std");

const co = @import("color.zig");
const dt = @import("datetime.zig");
const main = @import("main.zig");

pub const log_level_var = "HAT_LOG";
pub var level: Level = .none;

pub const Level = enum(u8) {
    none = 0,
    @"error",
    warn,
    info,
    debug,
    trace,

    fn ansi(self: Level) co.AnsiColor {
        return switch (self) {
            .none => unreachable,
            .@"error" => .red,
            .warn => .yellow,
            .info => .blue,
            .debug => .white,
            .trace => .bright_black,
        };
    }

    pub fn format(self: Level, writer: *std.io.Writer) std.io.Writer.Error!void {
        try writer.print("{f}", .{self.ansi()});
        try switch (self) {
            .none => unreachable,
            .@"error" => writer.writeAll("err"),
            .warn => writer.writeAll("wrn"),
            .info => writer.writeAll("inf"),
            .debug => writer.writeAll("dbg"),
            .trace => writer.writeAll("trc"),
        };
        try writer.writeAll(co.AnsiColor.reset);
    }
};

pub fn err(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    log(caller, .@"error", fmt, args);
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

pub fn trace(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    log(caller, .trace, fmt, args);
}

pub fn assertEql(comptime Caller: type, comptime T: type, actual: []const T, expected: []const T) void {
    if (!std.mem.eql(T, actual, expected)) {
        err(Caller, "assert failed:\n  actual: {any}\n  expected: {any}\n", .{ actual, expected });
        unreachable;
    }
}

pub fn enabled(lvl: Level) bool {
    return @intFromEnum(lvl) <= @intFromEnum(level);
}

pub fn init() void {
    if (std.posix.getenv(log_level_var)) |level_var| {
        inline for (std.meta.fields(Level)) |l| {
            if (std.mem.eql(u8, l.name, level_var)) {
                level = @enumFromInt(l.value);
                break;
            }
        }
    }
    info(@This(), "logging enabled, level: {f}\n", .{level});
    info(@This(), "pid: {}\n", .{std.c.getpid()});
}

fn log(comptime caller: type, comptime lvl: Level, comptime fmt: []const u8, args: anytype) void {
    if (!enabled(lvl)) return;
    var now_buf: [32]u8 = undefined;
    const now_str = dt.Datetime.now().formatISO8601Buf(&now_buf, false) catch "";

    const writer = &main.std_err_writer.interface;
    writer.print(
        "{s} {f} {f}{s: <16}{s} ",
        .{ now_str, lvl, co.AnsiColor.magenta, callerName(caller), co.AnsiColor.reset },
    ) catch {};
    writer.print(fmt, args) catch {};
    writer.flush() catch {};
}

fn callerName(comptime caller: type) []const u8 {
    const caller_name_full = @typeName(caller);
    var caller_name_iter = std.mem.splitBackwardsScalar(u8, caller_name_full, '.');
    return caller_name_iter.next() orelse caller_name_full;
}
