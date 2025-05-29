const main = @import("main.zig");
const nc = @cImport({
    @cInclude("ncurses.h");
});

pub fn try_move_cursor(try_cursor: main.Cursor) void {
    const win_size = .{ .row = nc.getmaxy(nc.stdscr), .col = nc.getmaxx(nc.stdscr) };
    if (try_cursor.row < 0 or try_cursor.row > win_size.row - 1 or
        try_cursor.col < 0 or try_cursor.col > win_size.col - 1) return;
    (&main.cursor).* = try_cursor;
    main.needs_redraw = true;
}
