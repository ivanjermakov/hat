const std = @import("std");
const w = @cImport({
    @cInclude("wordexp.h");
});

pub fn expand(allocator: std.mem.Allocator, str: []u8) ![]u8 {
    var we: w.wordexp_t = undefined;
    defer w.wordfree(&we);
    const res = w.wordexp(@ptrCast(str), &we, 0);
    if (res != 0) return error.Wordexp;

    const word = std.mem.span(we.we_wordv[0]);
    const expanded = try allocator.dupe(u8, word);
    return expanded;
}
