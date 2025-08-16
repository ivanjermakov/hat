const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn utf8FromBytes(allocator: Allocator, bytes: []const u8) ![]const u21 {
    var b = std.ArrayList(u21).init(allocator);
    const view = try std.unicode.Utf8View.init(bytes);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |ch| try b.append(ch);
    return b.toOwnedSlice();
}

pub fn utf8ToBytes(allocator: Allocator, utf: []const u21) ![]const u8 {
    var b = try std.ArrayList(u8).initCapacity(allocator, utf.len);
    try utf8ToBytesWrite(b.writer(), utf);
    return b.toOwnedSlice();
}

pub fn utf8ToBytesWrite(writer: anytype, utf: []const u21) !void {
    var pos: usize = 0;
    var buf: [1024]u8 = undefined;
    for (utf) |ch| {
        const len = try std.unicode.utf8Encode(ch, &buf);
        try writer.writeAll(buf[0..len]);
        pos += len;
    }
}

pub fn utf8ByteLen(utf: []const u21) !usize {
    var len: usize = 0;
    for (utf) |ch| len += try std.unicode.utf8CodepointSequenceLength(ch);
    return len;
}
