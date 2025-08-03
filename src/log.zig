const std = @import("std");
const main = @import("main.zig");
const dt = @import("datetime.zig");

pub var enabled = false;

pub fn log(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    const writer = main.std_err.writer();

    var now_buf: [32]u8 = undefined;
    const now_str = dt.Datetime.now().formatISO8601Buf(&now_buf, false) catch "";

    std.fmt.format(writer, "{s} {s}{s: <16}{s} ", .{ now_str, color(5), callerName(caller), colorReset() }) catch {};
    std.fmt.format(writer, fmt, args) catch {};
}

pub fn assertEql(comptime Caller: type, comptime T: type, actual: []const T, expected: []const T) void {
    if (!std.mem.eql(T, actual, expected)) {
        log(Caller, "assert failed:\n  actual: {any}\n  expected: {any}\n", .{ actual, expected });
        unreachable;
    }
}

fn callerName(comptime caller: type) []const u8 {
    const caller_name_full = @typeName(caller);
    var caller_name_iter = std.mem.splitBackwardsScalar(u8, caller_name_full, '.');
    return caller_name_iter.next() orelse caller_name_full;
}

fn color(comptime color_code: u8) []const u8 {
    const escapeCode = "\x1b[38;5;";
    return std.fmt.comptimePrint(
        "{s}{}{s}",
        .{ escapeCode, color_code, "m" },
    );
}

fn colorReset() []const u8 {
    return std.fmt.comptimePrint("\x1b[0m", .{});
}
