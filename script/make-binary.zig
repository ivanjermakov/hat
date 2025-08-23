const std = @import("std");

pub fn main() !void {
    var buf = std.mem.zeroes([256]u8);
    for (0..256) |i| {
        buf[i] = @intCast(i);
    }
    std.debug.print("buf: {any}\n", .{buf});
    const f = try std.fs.cwd().createFile("example/bytes.dat", .{});
    _ = try f.writeAll(&buf);
}
