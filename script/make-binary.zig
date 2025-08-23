const std = @import("std");

pub fn main() !void {
    try makeBytes();
    try makeBytesNl();
}

pub fn makeBytes() !void {
    var buf = std.mem.zeroes([256]u8);
    for (0..256) |i| {
        buf[i] = @intCast(i);
    }
    const f = try std.fs.cwd().createFile("example/bytes.dat", .{});
    _ = try f.writeAll(&buf);
}

pub fn makeBytesNl() !void {
    var buf = std.mem.zeroes([2 * 256]u8);
    for (0..256) |i| {
        buf[2 * i] = @intCast(i);
        buf[2 * i + 1] = '\n';
    }
    const f = try std.fs.cwd().createFile("example/bytes-nl.dat", .{});
    _ = try f.writeAll(&buf);
}
