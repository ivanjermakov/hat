const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn unicodeFromBytes(allocator: Allocator, bytes: []const u8) ![]const u21 {
    const b = try allocator.alloc(u21, bytes.len);
    const len = try unicodeFromBytesBuf(b, bytes);
    return b[0..len];
}

pub fn unicodeFromBytesBuf(buf: []u21, bytes: []const u8) !usize {
    const view = std.unicode.Utf8View.initUnchecked(bytes);
    var iter = view.iterator();
    var written: usize = 0;
    while (iter.nextCodepoint()) |ch| {
        buf[written] = ch;
        written += 1;
    }
    return written;
}

pub fn unicodeToBytes(allocator: Allocator, utf: []const u21) ![]const u8 {
    var b = try std.ArrayList(u8).initCapacity(allocator, utf.len);
    try unicodeToBytesWrite(b.writer(), utf);
    return b.toOwnedSlice();
}

pub fn unicodeToBytesWrite(writer: anytype, utf: []const u21) !void {
    var pos: usize = 0;
    var buf: [1024]u8 = undefined;
    for (utf) |ch| {
        const len = try std.unicode.utf8Encode(ch, &buf);
        try writer.writeAll(buf[0..len]);
        pos += len;
    }
}

pub fn unicodeByteLen(utf: []const u21) !usize {
    var len: usize = 0;
    for (utf) |ch| len += try std.unicode.utf8CodepointSequenceLength(ch);
    return len;
}
