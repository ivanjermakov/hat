const std = @import("std");
const main = @import("main.zig");
const nc = @cImport({
    @cInclude("ncurses.h");
});

pub fn move_cursor(new_cursor: main.Cursor) void {
    (&main.cursor).* = new_cursor;
    validate_cursor();
    main.needs_redraw = true;
}

pub fn insert_text(text: []u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepointSlice()) |ch| {
        const cbp = cursor_byte_pos();
        var line = &main.buffer.content.items[@intCast(cbp.row)];

        if (std.mem.eql(u8, ch, "\n")) {
            try insert_newline();
        } else {
            try line.insertSlice(@intCast(cbp.col), ch);
            main.cursor.col += 1;
        }
    }
    main.needs_reparse = true;
}

pub fn insert_newline() !void {
    const cbp = cursor_byte_pos();
    const row: usize = @intCast(main.cursor.row);
    var line = try main.buffer.content.items[row].toOwnedSlice();
    try main.buffer.content.items[row].appendSlice(line[0..@intCast(cbp.col)]);
    var new_line = std.ArrayList(u8).init(main.allocator);
    try new_line.appendSlice(line[@intCast(cbp.col)..]);
    try main.buffer.content.insert(@intCast(cbp.row + 1), new_line);
    main.cursor.row += 1;
    main.cursor.col = 0;
    main.needs_reparse = true;
}

pub fn remove_char() !void {
    const cbp = cursor_byte_pos();
    var line = &main.buffer.content.items[@intCast(main.cursor.row)];
    _ = line.orderedRemove(@intCast(cbp.col));
    main.needs_reparse = true;
}

pub fn remove_prev_char() !void {
    const cbp = cursor_byte_pos();
    if (cbp.col == 0) return;
    main.cursor.col -= 1;
    var line = &main.buffer.content.items[@intCast(main.cursor.row)];
    const col_byte = try utf8_byte_pos(line.items, @intCast(main.cursor.col));
    _ = line.orderedRemove(col_byte);
    main.needs_reparse = true;
}

fn cursor_byte_pos() main.Cursor {
    const row = main.cursor.row;
    var col: i32 = 0;
    b: {
        if (row >= main.buffer.content.items.len) break :b;
        const line = &main.buffer.content.items[@intCast(main.cursor.row)];
        col = @intCast(utf8_byte_pos(line.items, @intCast(main.cursor.col)) catch break :b);
    }
    return .{ .row = row, .col = col };
}

/// Find a byte position of a codepoint at cp_index in a UTF-8 byte string
fn utf8_byte_pos(str: []u8, cp_index: usize) !usize {
    const view = try std.unicode.Utf8View.init(str);
    var iter = view.iterator();
    var pos: usize = 0;
    var i: usize = 0;
    if (i == cp_index) return pos;
    while (iter.nextCodepointSlice()) |ch| {
        i += 1;
        pos += ch.len;
        if (i == cp_index) return pos;
    }
    return error.OutOfBounds;
}

fn validate_cursor() void {
    const win_size = .{ .row = nc.getmaxy(nc.stdscr), .col = nc.getmaxx(nc.stdscr) };
    main.cursor.row = std.math.clamp(main.cursor.row, 0, win_size.row - 1);
    main.cursor.col = std.math.clamp(main.cursor.col, 0, win_size.col - 1);
}
