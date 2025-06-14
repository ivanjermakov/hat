const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("locale.h");
    @cInclude("ncurses.h");
});
const co = @import("color.zig");
const fs = @import("fs.zig");

pub fn init_curses() !*c.WINDOW {
    const win = c.initscr() orelse return error.InitScr;
    _ = c.use_default_colors();
    _ = c.noecho();
    _ = c.setlocale(c.LC_ALL, "");

    if (c.has_colors()) {
        _ = c.start_color();
    }

    co.init_color();

    _ = c.bkgd(@intCast(co.ColorPair.text.to_pair()));

    return win;
}

pub fn setup_terminal() !void {
    var tty: c.struct_termios = undefined;
    _ = c.tcgetattr(std.posix.STDIN_FILENO, &tty);
    tty.c_lflag &= @bitCast(~(c.ICANON | c.ECHO));
    _ = c.tcsetattr(std.posix.STDIN_FILENO, c.TCSANOW, &tty);

    fs.make_nonblock(std.posix.STDIN_FILENO);
}
