const std = @import("std");

pub const Args = struct {
    path: ?[]u8 = null,
};

pub fn main() void {
    std.debug.print("Hello, World!", .{});
}
