const std = @import("std");
const main = @import("main.zig");
const dt = @import("datetime.zig");

pub fn log(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    if (!main.log_enabled) return;
    const allocator = main.allocator;

    const now_str = dt.Datetime.now().formatISO8601(allocator, false) catch "";
    defer allocator.free(now_str);

    const caller_name = @typeName(caller);

    const str = std.fmt.allocPrint(allocator, fmt, args) catch "";
    defer allocator.free(str);

    std.debug.print("{s} [{s}] {s}", .{ now_str, caller_name, str });
}
