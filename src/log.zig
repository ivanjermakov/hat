const std = @import("std");
const main = @import("main.zig");
const dt = @import("datetime.zig");

pub fn log(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    if (!main.log_enabled) return;
    const writer = main.std_err.writer();

    dt.Datetime.now().formatISO8601(writer, false) catch {};
    _ = writer.write(" ") catch {};
    printCaller(caller, writer) catch {};
    _ = writer.write(" ") catch {};
    std.fmt.format(writer, fmt, args) catch {};
}

fn printCaller(comptime caller: type, writer: anytype) !void {
    const caller_name_full = @typeName(caller);
    var caller_name_iter = std.mem.splitBackwardsScalar(u8, caller_name_full, '.');
    const caller_name = caller_name_iter.next() orelse caller_name_full;
    colored(writer, 5) catch {};
    std.fmt.format(writer, "{s: <16}", .{caller_name}) catch {};
    colorReset(writer) catch {};
}

fn colored(writer: anytype, color_code: u8) !void {
    const escapeCode = "\x1b[38;5;";
    try std.fmt.format(
        writer,
        "{s}{}{s}",
        .{ escapeCode, color_code, "m" },
    );
}

fn colorReset(writer: anytype) !void {
    const resetCode = "\x1b[0m";
    _ = try writer.write(resetCode);
}
