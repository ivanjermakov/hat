const std = @import("std");

pub fn utf8FromBytes(allocator: std.mem.Allocator, bytes: []const u8) ![]const u21 {
    var b = std.ArrayList(u21).init(allocator);
    const view = try std.unicode.Utf8View.init(bytes);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |ch| try b.append(ch);
    return b.toOwnedSlice();
}

pub fn utf8ToBytes(allocator: std.mem.Allocator, utf: []const u21) ![]const u8 {
    var total_size: usize = 0;
    for (utf) |ch| total_size += try std.unicode.utf8CodepointSequenceLength(ch);
    var b = try allocator.alloc(u8, total_size);
    var pos: usize = 0;
    for (utf) |ch| {
        const len = try std.unicode.utf8Encode(ch, b[pos..]);
        pos += len;
    }
    return b;
}
