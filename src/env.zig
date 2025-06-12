const std = @import("std");
const w = @cImport({
    @cInclude("wordexp.h");
});

pub fn expand(allocator: std.mem.Allocator, str: []u8) ![]u8 {
    var we: w.wordexp_t = undefined;
    const res = w.wordexp(@ptrCast(str), &we, 0);
    if (res != 0) return error.Wordexp;
    std.debug.print("{any}\n", .{we.we_wordv});
    const word = std.mem.sliceTo(@as([*c]u8, we.we_wordv[0]), 0);
    const expanded = try allocator.dupeZ(u8, word);
    w.wordfree(&we);
    return expanded;
}
