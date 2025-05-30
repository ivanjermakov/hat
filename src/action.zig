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
