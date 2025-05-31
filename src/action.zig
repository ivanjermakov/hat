const std = @import("std");
const main = @import("main.zig");
const nc = @cImport({
    @cInclude("ncurses.h");
});

pub fn validate_cursor() void {
    const win_size = .{ .row = nc.getmaxy(nc.stdscr), .col = nc.getmaxx(nc.stdscr) };
    main.cursor.row = std.math.clamp(main.cursor.row, 0, win_size.row - 1);
    main.cursor.col = std.math.clamp(main.cursor.col, 0, win_size.col - 1);
}

pub fn insert_text(text: []u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |ch| {
        if (std.mem.eql(u8, ch, "\n")) return error.TodoNewLine;
        var line = &main.buffer.items[@intCast(main.cursor.row)];
        const col_byte = try utf8_byte_pos(line.items, @intCast(main.cursor.col));
        try line.insertSlice(col_byte, ch);
        main.cursor.col += 1;
    }
}

/// Find a byte position of a codepoint at cp_index in a UTF-8 byte string
fn utf8_byte_pos(str: []u8, cp_index: usize) !usize {
    const view = try std.unicode.Utf8View.init(str);
    var iter = view.iterator();
    var pos: usize = 0;
    var i: usize = 0;
    while (iter.nextCodepointSlice()) |ch| {
        if (i == cp_index) return pos;
        std.debug.print("{}\n", .{ch.len});
        i += 1;
        pos += ch.len;
    }
    return error.OutOfBounds;
}
