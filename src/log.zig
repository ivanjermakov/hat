const std = @import("std");
const main = @import("main.zig");
const dt = @import("datetime.zig");

pub fn log(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    if (!main.log_enabled) return;
    const allocator = main.allocator;

    const now_str = dt.Datetime.now().formatISO8601(allocator, false) catch "";
    defer allocator.free(now_str);

    const caller_name = @typeName(caller);
    const caller_name_colored = color(allocator, caller_name, 5) catch "";
    defer allocator.free(caller_name_colored);
    const caller_name_bracketed = std.fmt.allocPrint(allocator, "[{s}]", .{caller_name_colored}) catch "";
    defer allocator.free(caller_name_bracketed);

    const str = std.fmt.allocPrint(allocator, fmt, args) catch "";
    defer allocator.free(str);

    std.debug.print("{s} {s: <30} {s}", .{ now_str, caller_name_bracketed, str });
}

fn color(allocator: std.mem.Allocator, str: []const u8, color_code: u8) ![]const u8 {
    const escapeCode = "\x1b[38;5;";
    const resetCode = "\x1b[0m";
    return try std.fmt.allocPrint(
        allocator,
        "{s}{}{s}{s}{s}",
        .{ escapeCode, color_code, "m", str, resetCode },
    );
}
