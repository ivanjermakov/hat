const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn unicodeFromBytes(allocator: Allocator, bytes: []const u8) ![]const u21 {
    const b = try allocator.alloc(u21, bytes.len);
    const len = try unicodeFromBytesBuf(b, bytes);
    return b[0..len];
}

pub fn unicodeFromBytesBuf(buf: []u21, bytes: []const u8) !usize {
    var iter = LooseUtf8Iterator{ .bytes = bytes };
    var written: usize = 0;
    while (iter.next()) |ch| {
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

/// Similar to std.unicode.Utf8Iterator, but handles non-unicode without panics.
/// Non-unicode bytes are returned as-is, just casting u8 to u21
pub const LooseUtf8Iterator = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(self: *LooseUtf8Iterator) ?u21 {
        if (self.i >= self.bytes.len) return null;

        var cp_len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch 1;
        defer self.i += cp_len;
        const try_slice = self.bytes[self.i .. self.i + cp_len];
        return std.unicode.utf8Decode(try_slice) catch {
            cp_len = 1;
            return try_slice[0];
        };
    }
};

/// Width of a unicode codepoint in terms of terminal cols
///
/// Returns:
///   - null for non printable
///   - 0 for combining/zero-width
///   - 1 for normal
///   - 2 for wide (CJK/fullwidth).
pub fn colWidth(ch: u21) ?usize {
    // C0 control chars
    if (ch == 0) return null;
    if (ch < 0x20 or (ch >= 0x7f and ch < 0xa0)) return null;

    // Combining marks and other zero-width characters (common ranges)
    // This list is a compact set of ranges that cover most combining marks and ZERO WIDTH characters.
    // Not exhaustive for every possible Unicode combining sequence, but sufficient for typical terminal use.
    const comb_ranges = &[_][2]u32{
        // Combining Diacritical Marks
        .{ 0x0300, 0x036F },
        // Combining Diacritical Marks Extended
        .{ 0x1AB0, 0x1AFF },
        // Combining Diacritical Marks Supplement
        .{ 0x1DC0, 0x1DFF },
        // Combining Half Marks
        .{ 0xFE20, 0xFE2F },
        // Variation Selectors
        .{ 0xFE00, 0xFE0F },
        // Zero Width
        .{ 0x200B, 0x200F },
        .{ 0x202A, 0x202E },
        // Combining Grapheme Joiner
        .{ 0x034F, 0x034F },
        // Additional zero-width / format controls
        .{ 0x0610, 0x061A },
        .{ 0x064B, 0x065F },
        .{ 0x06D6, 0x06DC },
        .{ 0x06DF, 0x06E4 },
        .{ 0x06E7, 0x06E8 },
        .{ 0x06EA, 0x06ED },
        .{ 0x0711, 0x0711 },
        .{ 0x0730, 0x074A },
        .{ 0x07A6, 0x07B0 },
        .{ 0x07EB, 0x07F3 },
        .{ 0x0816, 0x0819 },
        .{ 0x081B, 0x0823 },
        .{ 0x0825, 0x0827 },
        .{ 0x0829, 0x082D },
        .{ 0x0859, 0x085B },
        .{ 0x08D3, 0x08E1 },
        .{ 0x08E3, 0x0902 },
        .{ 0x093A, 0x093A },
        .{ 0x093C, 0x093C },
        .{ 0x0941, 0x0948 },
        .{ 0x094D, 0x094D },
        .{ 0x0951, 0x0957 },
        .{ 0x0962, 0x0963 },
        .{ 0x0981, 0x0981 },
        .{ 0x09BC, 0x09BC },
    };

    var i: usize = 0;
    while (i < comb_ranges.len) : (i += 1) {
        const r0 = comb_ranges[i][0];
        const r1 = comb_ranges[i][1];
        if (ch >= r0 and ch <= r1) return 0;
    }

    const wide_ranges = &[_][2]u32{
        .{ 0x1100, 0x115F }, // Hangul Jamo init
        .{ 0x2329, 0x232A },
        .{ 0x2E80, 0x2FFB },
        .{ 0x3000, 0x303E },
        .{ 0x3040, 0x3247 },
        .{ 0x3250, 0x4DBF },
        .{ 0x4E00, 0xA4C6 },
        .{ 0xA960, 0xA97C },
        .{ 0xAC00, 0xD7A3 }, // Hangul Syllables
        .{ 0xF900, 0xFAFF },
        .{ 0xFE10, 0xFE19 },
        .{ 0xFE30, 0xFE6B },
        .{ 0xFF01, 0xFF60 },
        .{ 0xFFE0, 0xFFE6 },
        .{ 0x1B000, 0x1B001 },
        .{ 0x1F200, 0x1F251 },
        .{ 0x20000, 0x3FFFD },
    };

    i = 0;
    while (i < wide_ranges.len) : (i += 1) {
        const r0 = wide_ranges[i][0];
        const r1 = wide_ranges[i][1];
        if (ch >= r0 and ch <= r1) return 2;
    }

    // Default: printable, width 1
    return 1;
}
