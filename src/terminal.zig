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
const inp = @import("input.zig");
const cmp = @import("ui/completion_menu.zig");
const uni = @import("unicode.zig");

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
    dimensions: TerminalDimensions,

    pub fn init(std_out_writer: std.io.AnyWriter, dimensions: TerminalDimensions) !Terminal {
        _ = c.setlocale(c.LC_ALL, "");

        var tty: c.struct_termios = undefined;
        _ = c.tcgetattr(main.tty_in.handle, &tty);
        tty.c_lflag &= @bitCast(~(c.ICANON | c.ECHO));
        _ = c.tcsetattr(main.tty_in.handle, c.TCSANOW, &tty);

        var term = Terminal{
            .writer = .{ .unbuffered_writer = std_out_writer },
            .dimensions = dimensions,
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

    pub fn draw(self: *Terminal) !void {
        const buffer = main.editor.activeBuffer();
        try self.drawBuffer(buffer);

        const cmp_menu = &main.editor.completion_menu;
        try self.drawCompletionMenu(cmp_menu);

        try self.moveCursor(buffer.cursor.applyOffset(buffer.offset.negate()));

        try self.flush();
    }

    pub fn updateCursor(self: *Terminal) !void {
        const buffer = main.editor.activeBuffer();
        try self.moveCursor(buffer.cursor.applyOffset(buffer.offset.negate()));
        switch (main.editor.mode) {
            .normal => _ = try self.write(cursor_type.steady_block),
            .select, .select_line => _ = try self.write(cursor_type.steady_underline),
            .insert => _ = try self.write(cursor_type.steady_bar),
        }
        try self.flush();
    }

    pub fn updateInput(self: *Terminal, allocator: std.mem.Allocator) !bool {
        _ = self;
        var dirty = false;
        if (try getCodes(allocator)) |codes| {
            defer allocator.free(codes);
            dirty = true;
            const new_keys = try getKeys(allocator, codes);
            defer allocator.free(new_keys);
            try main.key_queue.appendSlice(new_keys);
        }
        return dirty;
    }

    fn clear(self: *Terminal) !void {
        try self.write("\x1b[2J");
    }

    fn clearUntilLineEnd(self: *Terminal) !void {
        try self.write("\x1b[0K");
    }

    pub fn switchBuf(self: *Terminal, alternative: bool) !void {
        try self.write(if (alternative) "\x1b[?1049h" else "\x1b[?1049l");
    }

    fn resetAttributes(self: *Terminal) !void {
        try self.write("\x1b[0m");
    }

    fn moveCursor(self: *Terminal, cursor: buf.Cursor) !void {
        try self.format("\x1b[{};{}H", .{ cursor.row + 1, cursor.col + 1 });
    }

    fn writeAttr(self: *Terminal, attr: co.Attr) !void {
        try attr.write(self.writer.writer());
    }

    fn write(self: *Terminal, str: []const u8) !void {
        _ = try self.writer.write(str);
    }

    fn flush(self: *Terminal) !void {
        try self.writer.flush();
    }

    fn format(self: *Terminal, comptime str: []const u8, args: anytype) !void {
        try std.fmt.format(self.writer.writer(), str, args);
    }

    fn drawBuffer(self: *Terminal, buffer: *buf.Buffer) !void {
        var attrs_buf = std.mem.zeroes([128]u8);
        var attrs_stream = std.io.fixedBufferStream(&attrs_buf);
        var attrs: []const u8 = undefined;
        var last_attrs_buf = std.mem.zeroes([128]u8);
        var last_attrs: ?[]const u8 = null;

        try self.clear();
        var span_index: usize = 0;
        for (0..self.dimensions.height) |term_row| {
            const buffer_row = @as(i32, @intCast(term_row)) + buffer.offset.row;
            if (buffer_row < 0) continue;
            if (buffer_row >= buffer.content.items.len) break;

            var byte: usize = buffer.line_positions.items[@intCast(buffer_row)];
            var term_col: i32 = 0;

            var line = buffer.content.items[@intCast(buffer_row)].items;
            try self.moveCursor(.{ .row = @intCast(term_row), .col = 0 });

            if (buffer.offset.col > 0) {
                if (buffer.offset.col >= line.len) continue;
                const offscreen_line = line[0..@intCast(buffer.offset.col)];
                byte += try uni.utf8ByteLen(offscreen_line);
                line = line[@intCast(buffer.offset.col)..];
            } else {
                for (0..@intCast(-buffer.offset.col)) |_| {
                    try self.write(" ");
                }
            }

            for (line) |ch| {
                attrs_stream.reset();
                const buffer_col = @as(i32, @intCast(term_col)) + buffer.offset.col;

                if (term_col >= self.dimensions.width) break;
                const ch_attrs: []const co.Attr = b: while (span_index < buffer.spans.items.len) {
                    const span = buffer.spans.items[span_index];
                    if (span.span.start_byte > byte) break :b co.attributes.text;
                    if (byte >= span.span.start_byte and byte < span.span.end_byte) {
                        break :b span.attrs;
                    }
                    span_index += 1;
                } else {
                    break :b co.attributes.text;
                };
                try co.attributes.write(ch_attrs, attrs_stream.writer());

                if (buffer.selection) |selection| {
                    if (selection.inRangeInclusive(.{ .row = buffer_row, .col = buffer_col })) {
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
            // reached line end
            try self.resetAttributes();
            last_attrs = null;
        }
    }

    fn drawCompletionMenu(self: *Terminal, cmp_menu: *cmp.CompletionMenu) !void {
        const max_width = 30;

        if (main.editor.mode != .insert) return;
        if (cmp_menu.display_items.items.len == 0) return;

        const buffer = main.editor.activeBuffer();
        const replace_range = cmp_menu.replace_range.?;
        const menu_pos = (buf.Cursor{
            .row = @intCast(replace_range.start.line),
            .col = @intCast(replace_range.start.character),
        })
            .applyOffset(buffer.offset.negate())
            .applyOffset(.{ .row = 1 });

        try self.resetAttributes();

        var longest_item: usize = 0;
        for (cmp_menu.display_items.items) |idx| {
            const cmp_item = cmp_menu.completion_items.items[idx];
            if (cmp_item.label.len > longest_item) longest_item = cmp_item.label.len;
        }
        const menu_width = @min(max_width, longest_item);

        for (0..cmp_menu.display_items.items.len) |menu_row| {
            const idx = cmp_menu.display_items.items[menu_row];
            const cmp_item = cmp_menu.completion_items.items[idx];
            try self.moveCursor(.{
                .row = menu_pos.row + @as(i32, @intCast(menu_row)),
                .col = menu_pos.col,
            });
            if (menu_row == cmp_menu.active_item) {
                try co.attributes.write(co.attributes.completion_menu_active, self.writer.writer());
            } else {
                try co.attributes.write(co.attributes.completion_menu, self.writer.writer());
            }
            try self.write(cmp_item.label[0..@min(cmp_item.label.len, menu_width)]);

            const padding_len: i32 = menu_width - @as(i32, @intCast(cmp_item.label.len));
            if (padding_len > 0) {
                for (0..@intCast(padding_len)) |_| {
                    try self.write(" ");
                }
            }
        }

        try self.resetAttributes();
    }
};

pub fn terminalSize() !TerminalDimensions {
    var w: std.c.winsize = undefined;
    if (std.c.ioctl(main.std_out.handle, std.c.T.IOCGWINSZ, &w) == -1) {
        return error.TermSize;
    }
    return .{
        .width = w.col,
        .height = w.row,
    };
}

pub const HighlightConfig = struct {
    term_height: usize,
    highlight_line: usize,

    pub fn fromArgs(args: main.Args) !?HighlightConfig {
        if (args.highlight_line == null) return null;
        return .{
            .highlight_line = args.highlight_line.?,
            .term_height = args.term_height orelse (try terminalSize()).height,
        };
    }
};

pub fn printBuffer(buffer: *buf.Buffer, writer: std.io.AnyWriter, highlight: ?HighlightConfig) !void {
    var buf_writer = std.io.bufferedWriter(writer);
    var w = buf_writer.writer();

    var attrs_buf = std.mem.zeroes([128]u8);
    var attrs_stream = std.io.fixedBufferStream(&attrs_buf);
    var attrs: []const u8 = undefined;
    var last_attrs_buf = std.mem.zeroes([128]u8);
    var last_attrs: ?[]const u8 = null;

    var start_row: i32 = 0;
    var end_row: i32 = @intCast(buffer.content.items.len);
    if (highlight) |hi| {
        const half_term: i32 = @divFloor(@as(i32, @intCast(hi.term_height)), 2);
        start_row = @as(i32, @intCast(hi.highlight_line)) - half_term;
        end_row = start_row + @as(i32, @intCast(hi.term_height));
    }

    var span_index: usize = 0;
    var row: i32 = start_row;
    while (row < end_row) {
        defer {
            _ = w.write("\x1b[0m") catch {};
            _ = w.write("\n") catch {};
            last_attrs = null;
            row += 1;
        }
        if (row < 0 or row >= buffer.content.items.len) continue;
        const line = buffer.content.items[@intCast(row)].items;

        var byte: usize = buffer.line_positions.items[@intCast(row)];
        var term_col: i32 = 0;

        for (line) |ch| {
            attrs_stream.reset();
            const ch_attrs: []const co.Attr = b: while (span_index < buffer.spans.items.len) {
                const span = buffer.spans.items[span_index];
                if (span.span.start_byte > byte) break :b co.attributes.text;
                if (byte >= span.span.start_byte and byte < span.span.end_byte) {
                    break :b span.attrs;
                }
                span_index += 1;
            } else {
                break :b co.attributes.text;
            };
            try co.attributes.write(ch_attrs, attrs_stream.writer());

            if (highlight != null and row == highlight.?.highlight_line) {
                try co.attributes.write(co.attributes.selection, attrs_stream.writer());
            }

            attrs = attrs_stream.getWritten();
            if (last_attrs == null or !std.mem.eql(u8, attrs, last_attrs.?)) {
                _ = try w.write("\x1b[0m");
                _ = try w.write(attrs);
                @memcpy(&last_attrs_buf, &attrs_buf);
                last_attrs = last_attrs_buf[0..try attrs_stream.getPos()];
            }

            try std.fmt.format(w, "{u}", .{ch});

            byte += try std.unicode.utf8CodepointSequenceLength(ch);
            term_col += 1;
        }
    }
    try buf_writer.flush();
}

pub fn parseAnsi(allocator: std.mem.Allocator, input: *std.ArrayList(u8)) !inp.Key {
    var key: inp.Key = .{};
    const code = input.orderedRemove(0);
    s: switch (code) {
        0x00...0x08, 0x0e, 0x10...0x19 => {
            // offset 96 converts \x1 to 'a', \x2 to 'b', and so on
            // TODO: might not be printable
            key.printable = try allocator.dupe(u8, &.{code + 96});
            key.modifiers = @intFromEnum(inp.Modifier.control);
        },
        0x09 => key.code = .tab,
        0x7f => key.code = .backspace,
        0x0d => key.printable = try allocator.dupe(u8, &.{'\n'}),
        0x1b => {
            if (input.items.len > 0 and input.items[0] == '[') {
                _ = input.orderedRemove(0);
                if (input.items.len > 0) {
                    switch (input.items[0]) {
                        'A' => {
                            _ = input.orderedRemove(0);
                            key.code = .up;
                            break :s;
                        },
                        'B' => {
                            _ = input.orderedRemove(0);
                            key.code = .down;
                            break :s;
                        },
                        'C' => {
                            _ = input.orderedRemove(0);
                            key.code = .right;
                            break :s;
                        },
                        'D' => {
                            _ = input.orderedRemove(0);
                            key.code = .left;
                            break :s;
                        },
                        '3' => {
                            _ = input.orderedRemove(0);
                            if (input.items.len > 0 and input.items[0] == '~') _ = input.orderedRemove(0);
                            key.code = .delete;
                            break :s;
                        },
                        else => return error.TodoCsi,
                    }
                }
            }
            key.code = .escape;
            break :s;
        },
        else => {
            var printable = std.ArrayList(u8).init(allocator);
            defer printable.deinit();

            try printable.append(code);
            while (input.items.len > 0) {
                if (isPrintableAscii(input.items[0])) break;
                const code2 = input.orderedRemove(0);
                try printable.append(code2);
            }
            key.printable = try printable.toOwnedSlice();
        },
    }
    log.log(@This(), "{any}\n", .{key});
    return key;
}

pub fn getCodes(allocator: std.mem.Allocator) !?[]u8 {
    if (!fs.poll(main.tty_in)) return null;
    var in_buf = std.ArrayList(u8).init(allocator);
    while (true) {
        if (!fs.poll(main.tty_in)) break;
        var b: [1]u8 = undefined;
        const bytes_read = std.posix.read(main.tty_in.handle, &b) catch break;
        if (bytes_read == 0) break;
        try in_buf.appendSlice(b[0..]);
        // 1ns seems to be enough wait time for /dev/tty to fill up with the next code
        std.Thread.sleep(1);
    }
    if (in_buf.items.len == 0) return null;
    return try in_buf.toOwnedSlice();
}

pub fn getKeys(allocator: std.mem.Allocator, codes: []u8) ![]inp.Key {
    var keys = std.ArrayList(inp.Key).init(allocator);

    var cs = std.ArrayList(u8).init(allocator);
    defer cs.deinit();
    try cs.appendSlice(codes);

    while (cs.items.len > 0) {
        const key = parseAnsi(allocator, &cs) catch |e| {
            log.log(@This(), "{}\n", .{e});
            continue;
        };
        try keys.append(key);
    }
    return try keys.toOwnedSlice();
}

fn ansiCodeToString(allocator: std.mem.Allocator, code: u8) ![]u8 {
    const is_printable = code >= 32 and code < 127;
    if (is_printable) {
        return std.fmt.allocPrint(allocator, "{c}", .{@as(u7, @intCast(code))});
    } else {
        return std.fmt.allocPrint(allocator, "\\x{x}", .{code});
    }
}

fn isPrintableAscii(code: u8) bool {
    return code >= 0x21 and code <= 0x7e;
}
