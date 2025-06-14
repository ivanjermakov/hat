const std = @import("std");
const posix = std.posix;

pub fn read_nonblock(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var res = std.ArrayList(u8).init(allocator);
    errdefer res.deinit();

    var b: [2048]u8 = undefined;
    while (true) {
        const read_len = file.read(&b) catch |e| {
            switch (e) {
                error.WouldBlock => break,
                else => return e,
            }
        };
        if (read_len == 0) break;
        try res.appendSlice(b[0..read_len]);
    }
    if (res.items.len == 0) {
        res.deinit();
        return null;
    }
    return try res.toOwnedSlice();
}

pub fn make_nonblock(fd: posix.fd_t) void {
    _ = posix.fcntl(
        fd,
        posix.F.SETFL,
        posix.fcntl(fd, posix.F.GETFL, 0) catch return | posix.SOCK.NONBLOCK,
    ) catch return;
}
