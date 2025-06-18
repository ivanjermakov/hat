const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("locale.h");
});
const main = @import("main.zig");
const co = @import("color.zig");
const fs = @import("fs.zig");

pub const TerminalDimensions = struct {
    width: usize,
    height: usize,
};

/// See section about "CSI Ps SP q" at
/// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Functions-using-CSI-_-ordered-by-the-final-character_s_
pub const cursor_type = union {
    pub const blinking_block = "\x1b[0 q";
    pub const blinking_block2 = "\x1b[1 q";
    pub const steady_block = "\x1b[2 q";
    pub const blinking_underline = "\x1b[3 q";
    pub const steady_underline = "\x1b[4 q";
    pub const blinking_bar = "\x1b[5 q";
    pub const steady_bar = "\x1b[6 q";
};

pub const Term = struct {
    writer: std.io.BufferedWriter(4096, std.fs.File.Writer),

    pub fn init(std_out: std.fs.File) !Term {
        _ = c.setlocale(c.LC_ALL, "");

        var tty: c.struct_termios = undefined;
        _ = c.tcgetattr(std.posix.STDIN_FILENO, &tty);
        tty.c_lflag &= @bitCast(~(c.ICANON | c.ECHO));
        _ = c.tcsetattr(std.posix.STDIN_FILENO, c.TCSANOW, &tty);

        fs.make_nonblock(std.posix.STDIN_FILENO);

        var term = Term{
            .writer = std.io.bufferedWriter(std_out.writer()),
        };

        try term.switch_buf(true);

        return term;
    }

    pub fn deinit(self: *Term) void {
        self.clear() catch {};
        self.switch_buf(false) catch {};
        self.write(cursor_type.steady_block) catch {};
        self.flush() catch {};
    }

    pub fn terminal_size(self: *const Term) !TerminalDimensions {
        _ = self;
        var w: std.c.winsize = undefined;
        if (std.c.ioctl(main.std_out.handle, std.c.T.IOCGWINSZ, &w) == -1) {
            return error.TermSize;
        }
        return .{
            .width = w.row,
            .height = w.col,
        };
    }

    pub fn clear(self: *Term) !void {
        try self.write("\x1b[2J");
    }

    pub fn clear_until_line_end(self: *Term) !void {
        try self.write("\x1b[0K");
    }

    pub fn switch_buf(self: *Term, alternative: bool) !void {
        try self.write(if (alternative) "\x1b[?1049h" else "\x1b[?1049l");
    }

    pub fn reset_attributes(self: *Term) !void {
        try self.write("\x1b[0m");
    }

    pub fn move_cursor(self: *Term, cursor: main.Cursor) !void {
        try self.format("\x1b[{};{}H", .{ cursor.row + 1, cursor.col + 1 });
    }

    pub fn write_attr(self: *Term, attr: co.Attr) !void {
        try attr.write(self.writer.writer());
    }

    pub fn write_attrs(self: *Term, attrs: []const co.Attr) !void {
        for (attrs) |attr| try self.write_attr(attr);
    }

    pub fn write(self: *Term, str: []const u8) !void {
        _ = try self.writer.write(str);
    }

    pub fn flush(self: *Term) !void {
        try self.writer.flush();
    }

    pub fn format(self: *Term, comptime str: []const u8, args: anytype) !void {
        try std.fmt.format(self.writer.writer(), str, args);
    }
};
