const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("locale.h");
});
const main = @import("main.zig");
const buf = @import("buffer.zig");
const co = @import("color.zig");
const log = @import("log.zig");
const fs = @import("fs.zig");
const cmp = @import("ui/completion_menu.zig");

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

pub const Terminal = struct {
    writer: std.io.BufferedWriter(8192, std.io.AnyWriter),

    pub fn init(std_out_writer: std.io.AnyWriter) !Terminal {
        _ = c.setlocale(c.LC_ALL, "");

        var tty: c.struct_termios = undefined;
        _ = c.tcgetattr(std.posix.STDIN_FILENO, &tty);
        tty.c_lflag &= @bitCast(~(c.ICANON | c.ECHO));
        _ = c.tcsetattr(std.posix.STDIN_FILENO, c.TCSANOW, &tty);

        fs.makeNonblock(std.posix.STDIN_FILENO);

        var term = Terminal{
            .writer = .{ .unbuffered_writer = std_out_writer },
        };

        try term.switchBuf(true);

        return term;
    }

    pub fn deinit(self: *Terminal) void {
        self.clear() catch {};
        self.switchBuf(false) catch {};
        self.write(cursor_type.steady_block) catch {};
        self.flush() catch {};
    }

    pub fn terminalSize(self: *const Terminal) !TerminalDimensions {
        _ = self;
        var w: std.c.winsize = undefined;
        if (std.c.ioctl(main.std_out.handle, std.c.T.IOCGWINSZ, &w) == -1) {
            return error.TermSize;
        }
        return .{
            .width = w.col,
            .height = w.row,
        };
    }

    pub fn clear(self: *Terminal) !void {
        try self.write("\x1b[2J");
    }

    pub fn clearUntilLineEnd(self: *Terminal) !void {
        try self.write("\x1b[0K");
    }

    pub fn switchBuf(self: *Terminal, alternative: bool) !void {
        try self.write(if (alternative) "\x1b[?1049h" else "\x1b[?1049l");
    }

    pub fn resetAttributes(self: *Terminal) !void {
        try self.write("\x1b[0m");
    }

    pub fn moveCursor(self: *Terminal, cursor: buf.Cursor) !void {
        try self.format("\x1b[{};{}H", .{ cursor.row + 1, cursor.col + 1 });
    }

    pub fn writeAttr(self: *Terminal, attr: co.Attr) !void {
        try attr.write(self.writer.writer());
    }

    pub fn write(self: *Terminal, str: []const u8) !void {
        _ = try self.writer.write(str);
    }

    pub fn flush(self: *Terminal) !void {
        try self.writer.flush();
    }

    pub fn format(self: *Terminal, comptime str: []const u8, args: anytype) !void {
        try std.fmt.format(self.writer.writer(), str, args);
    }

    pub fn draw(self: *Terminal) !void {
        const buffer = main.editor.active_buffer.?;
        try self.drawBuffer(buffer);

        const cmp_menu = &main.editor.completion_menu;
        try self.drawCompletionMenu(cmp_menu);

        try self.moveCursor(buffer.cursor.applyOffset(buffer.offset.negate()));

        try self.flush();
    }

    fn drawBuffer(self: *Terminal, buffer: *buf.Buffer) !void {
        var attrs_buf = std.mem.zeroes([128]u8);
        var attrs_stream = std.io.fixedBufferStream(&attrs_buf);
        var attrs: []const u8 = undefined;
        var last_attrs_buf = std.mem.zeroes([128]u8);
        var last_attrs: ?[]const u8 = null;

        try self.clear();
        const dims = try self.terminalSize();

        for (0..dims.height) |term_row| {
            const buffer_row = @as(i32, @intCast(term_row)) + buffer.offset.row;
            if (buffer_row < 0) continue;
            if (buffer_row >= buffer.content.items.len) break;

            var byte: usize = buffer.line_positions.items[@intCast(buffer_row)];
            var term_col: i32 = 0;

            const line: []u8 = buffer.content.items[@intCast(buffer_row)].items;
            const line_view = try std.unicode.Utf8View.init(line);
            var line_iter = line_view.iterator();
            try self.moveCursor(.{ .row = @intCast(term_row), .col = 0 });

            if (buffer.offset.col > 0) {
                for (0..@intCast(buffer.offset.col)) |_| {
                    if (line_iter.nextCodepoint()) |ch| {
                        byte += try std.unicode.utf8CodepointSequenceLength(ch);
                    }
                }
            } else {
                for (0..@intCast(-buffer.offset.col)) |_| {
                    try self.write(" ");
                }
            }

            while (line_iter.nextCodepoint()) |ch| {
                attrs_stream.reset();
                const buffer_col = @as(i32, @intCast(term_col)) + buffer.offset.col;

                if (term_col >= dims.width) break;
                const ch_attrs: []co.Attr = b: for (buffer.spans.items) |span| {
                    if (span.span.start_byte <= byte and span.span.end_byte > byte) {
                        if (std.mem.eql(u8, span.node_type, "return") or
                            std.mem.eql(u8, span.node_type, "primitive_type") or
                            std.mem.eql(u8, span.node_type, "#include") or
                            std.mem.eql(u8, span.node_type, "export") or
                            std.mem.eql(u8, span.node_type, "function"))
                        {
                            break :b @constCast(co.attributes.keyword);
                        }
                        if (std.mem.eql(u8, span.node_type, "system_lib_string") or
                            std.mem.eql(u8, span.node_type, "string_literal") or
                            std.mem.eql(u8, span.node_type, "string"))
                        {
                            break :b @constCast(co.attributes.string);
                        }
                        if (std.mem.eql(u8, span.node_type, "number_literal")) {
                            break :b @constCast(co.attributes.number);
                        }
                        if (std.mem.eql(u8, span.node_type, "comment")) {
                            break :b @constCast(co.attributes.comment);
                        }
                    }
                } else {
                    break :b @constCast(co.attributes.text);
                };
                try co.attributes.write(ch_attrs, attrs_stream.writer());

                if (main.editor.mode == .select) {
                    if (buffer.selection.?.inRange(.{ .row = @intCast(buffer_row), .col = @intCast(buffer_col) })) {
                        try co.attributes.write(co.attributes.selection, attrs_stream.writer());
                    }
                }

                if (buffer.diagnostics.items.len > 0) {
                    for (buffer.diagnostics.items) |diagnostic| {
                        const range = diagnostic.range;
                        const in_range = (buffer_row > range.start.line and buffer_row < range.end.line) or
                            (buffer_row == range.start.line and buffer_col >= range.start.character and buffer_col < range.end.character);
                        if (in_range) {
                            try co.attributes.write(co.attributes.diagnostic_error, attrs_stream.writer());
                            break;
                        }
                    }
                }

                attrs = attrs_stream.getWritten();
                if (last_attrs == null or !std.mem.eql(u8, attrs, last_attrs.?)) {
                    self.resetAttributes() catch {};
                    try self.write(attrs);
                    @memcpy(&last_attrs_buf, &attrs_buf);
                    last_attrs = last_attrs_buf[0..try attrs_stream.getPos()];
                }

                try self.format("{u}", .{ch});

                byte += try std.unicode.utf8CodepointSequenceLength(ch);
                term_col += 1;
            }
        }
        switch (main.editor.mode) {
            .normal, .select => _ = try self.write(cursor_type.steady_block),
            .insert => _ = try self.write(cursor_type.steady_bar),
        }
    }

    fn drawCompletionMenu(self: *Terminal, cmp_menu: *cmp.CompletionMenu) !void {
        const max_width = 30;

        if (main.editor.mode != .insert) return;
        if (cmp_menu.display_items.items.len == 0) return;

        const buffer = main.editor.active_buffer.?;
        const replace_range = cmp_menu.replace_range.?;
        const menu_pos = (buf.Cursor{
            .row = @intCast(replace_range.start.line),
            .col = @intCast(replace_range.start.character),
        })
            .applyOffset(buffer.offset.negate())
            .applyOffset(.{ .row = 1, .col = 0 });

        try co.attributes.write(co.attributes.completion_menu, self.writer.writer());

        for (0..cmp_menu.display_items.items.len) |menu_row| {
            const idx = cmp_menu.display_items.items[menu_row];
            const cmp_item = cmp_menu.completion_items.items[idx];
            try self.moveCursor(.{
                .row = menu_pos.row + @as(i32, @intCast(menu_row)),
                .col = menu_pos.col,
            });
            try self.write(cmp_item.label[0..@min(cmp_item.label.len, max_width)]);

            const padding_len: i32 = max_width - @as(i32, @intCast(cmp_item.label.len));
            if (padding_len > 0) {
                for (0..@intCast(padding_len)) |_| {
                    try self.write(" ");
                }
            }
        }

        try self.resetAttributes();
    }
};
