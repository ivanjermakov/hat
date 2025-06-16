const std = @import("std");
const main = @import("main.zig");
const dt = @import("datetime.zig");

pub fn log(comptime caller: type, comptime fmt: []const u8, args: anytype) void {
    if (!main.log_enabled) return;
    const str = std.fmt.allocPrint(main.allocator, fmt, args) catch "";
    defer main.allocator.free(str);
    const caller_name = @typeName(caller);
    const now = dt.Datetime.now();
    const now_str = now.formatISO8601(main.allocator, false) catch "";
    defer main.allocator.free(now_str);
    std.debug.print("{s} [{s}] {s}", .{ now_str, caller_name, str });
}
