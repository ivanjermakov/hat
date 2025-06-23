const std = @import("std");
const posix = std.posix;

pub fn readNonblock(allocator: std.mem.Allocator, file: std.fs.File) !?[]u8 {
    var res = std.ArrayList(u8).init(allocator);
    errdefer res.deinit();

    var b: [4096]u8 = undefined;
    while (true) {
        if (!poll(file)) break;
        const read_len = try file.read(&b);
        if (read_len == 0) break;
        try res.appendSlice(b[0..read_len]);
    }
    if (res.items.len == 0) {
        res.deinit();
        return null;
    }
    return try res.toOwnedSlice();
}

pub fn poll(file: std.fs.File) bool {
    const fd = std.posix.pollfd{ .fd = file.handle, .events = std.c.POLL.IN, .revents = 0 };
    const count = std.posix.poll(@constCast(&[_]std.posix.pollfd{fd}), 0) catch return false;
    return count > 0;
}
