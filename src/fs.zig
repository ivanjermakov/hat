const std = @import("std");
const posix = std.posix;

pub fn readNonblock(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var res = std.ArrayList(u8).init(allocator);
    errdefer res.deinit();

    var b: [4096]u8 = undefined;
    while (true) {
        const read_len = file.read(&b) catch |e| {
            switch (e) {
                error.WouldBlock => break,
                else => return e,
            }
        };
        if (read_len == 0) break;
        try res.appendSlice(b[0..read_len]);
        // TODO: without hacks
        // 1ms seems to be enough wait time for next part of the message to come in
        std.Thread.sleep(1e6);
    }
    if (res.items.len == 0) {
        res.deinit();
        return null;
    }
    return try res.toOwnedSlice();
}

pub fn makeNonblock(fd: posix.fd_t) void {
    _ = posix.fcntl(
        fd,
        posix.F.SETFL,
        posix.fcntl(fd, posix.F.GETFL, 0) catch return | posix.SOCK.NONBLOCK,
    ) catch return;
}
