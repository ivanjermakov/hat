const std = @import("std");
const posix = std.posix;

pub fn readNonblock(writer: *std.io.Writer, file: std.fs.File) !void {
    if (!poll(file)) return;

    var b: [4096]u8 = undefined;
    while (true) {
        if (!poll(file)) break;
        const read_len = try file.read(&b);
        if (read_len == 0) break;
        try writer.writeAll(b[0..read_len]);
    }
}

pub fn poll(file: std.fs.File) bool {
    const fd = std.posix.pollfd{ .fd = file.handle, .events = std.c.POLL.IN, .revents = 0 };
    const count = std.posix.poll(@constCast(&[_]std.posix.pollfd{fd}), 0) catch return false;
    return count > 0;
}
