const std = @import("std");
const posix = std.posix;
const c = @cImport({
    @cInclude("termios.h");
    @cInclude("locale.h");
});
const main = @import("main.zig");
const core = @import("core.zig");
const buf = @import("buffer.zig");
const co = @import("color.zig");
const log = @import("log.zig");
const fs = @import("fs.zig");
const inp = @import("input.zig");
const cmp = @import("ui/completion_menu.zig");
const cmd = @import("ui/command_line.zig");
const uni = @import("unicode.zig");

const Dimensions = core.Dimensions;
const Area = core.Area;
const Cursor = core.Cursor;
const Layout = core.Layout;
const Allocator = std.mem.Allocator;

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
    dimensions: Dimensions,
    allocator: Allocator,

    pub fn init(allocator: Allocator, std_out_writer: std.io.AnyWriter, dimensions: Dimensions) !Terminal {
        var self = Terminal{
            .writer = .{ .unbuffered_writer = std_out_writer },
            .dimensions = dimensions,
            .allocator = allocator,
        };
        try self.setup();

        return self;
    }

    pub fn setup(self: *Terminal) !void {
        _ = c.setlocale(c.LC_ALL, "");

        var tty: c.struct_termios = undefined;
        _ = c.tcgetattr(main.tty_in.handle, &tty);
        tty.c_lflag &= @bitCast(~(c.ICANON | c.ECHO));
        _ = c.tcsetattr(main.tty_in.handle, c.TCSANOW, &tty);

        try self.switchBuf(true);
    }

    pub fn deinit(self: *Terminal) void {
        self.clear() catch {};
        self.switchBuf(false) catch {};
        self.write(cursor_type.steady_block) catch {};
        self.flush() catch {};
    }

    pub fn draw(self: *Terminal) !void {
        try self.clear();
        const buffer = main.editor.active_buffer;
        const layout = computeLayout(self.dimensions);

        try self.drawBuffer(buffer, layout.buffer);

        const cmp_menu = &main.editor.completion_menu;
        try self.drawCompletionMenu(cmp_menu);

        if (main.editor.hover_contents) |hover| try self.drawHover(hover);
        if (main.editor.command_line.command == null) try self.drawMessage();
        try self.updateCursor();
        if (main.editor.command_line.command != null) try self.drawCmd(&main.editor.command_line);

        try self.flush();
    }

    pub fn updateCursor(self: *Terminal) !void {
        const buffer = main.editor.active_buffer;
        const layout = computeLayout(self.dimensions);

        try self.drawNumberLine(buffer, layout.number_line);
        if (main.editor.command_line.command == null) try self.drawMessage();

        try self.moveCursor(buffer.cursor
            .applyOffset(buffer.offset.negate())
            .applyOffset(layout.buffer.pos));

        switch (main.editor.mode) {
            .normal => _ = try self.write(cursor_type.steady_block),
            .select, .select_line => _ = try self.write(cursor_type.steady_underline),
            .insert => _ = try self.write(cursor_type.steady_bar),
        }
        try self.flush();
    }

    fn clear(self: *Terminal) !void {
        try self.write("\x1b[2J");
    }

    fn clearUntilLineEnd(self: *Terminal) !void {
        try self.write("\x1b[0K");
    }

    pub fn switchBuf(self: *Terminal, alternative: bool) !void {
        try self.write(if (alternative) "\x1b[?1049h" else "\x1b[?1049l");
        try self.flush();
    }

    fn resetAttributes(self: *Terminal) !void {
        try self.write("\x1b[0m");
    }

    fn moveCursor(self: *Terminal, cursor: Cursor) !void {
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

    fn drawNumberLine(self: *Terminal, buffer: *buf.Buffer, area: Area) !void {
        try co.attributes.write(co.attributes.number_line, self.writer.writer());
        defer self.resetAttributes() catch {};
        const cursor_row = buffer.cursor.row;
        for (@intCast(area.pos.row)..@as(usize, @intCast(area.pos.row)) + area.dims.height) |term_row| {
            const buffer_row = @as(i32, @intCast(term_row)) + buffer.offset.row;
            try self.moveCursor(.{ .row = @intCast(term_row), .col = area.pos.col });
            if (buffer_row < 0 or buffer_row >= buffer.line_positions.items.len) {
                // TODO: option to show "~"
            } else {
                // TODO: option to use non-relative line numbers
                var display_num: usize = 0;
                var alignment: std.fmt.Alignment = .right;
                const line_num: i32 = cursor_row - buffer_row;
                if (line_num == 0) {
                    display_num = @intCast(cursor_row + 1);
                    alignment = .center;
                } else {
                    display_num = @abs(line_num);
                }
                try std.fmt.formatInt(
                    display_num,
                    10,
                    .lower,
                    .{ .width = area.dims.width - 1, .alignment = alignment },
                    self.writer.writer(),
                );
            }
        }
    }

    fn drawBuffer(self: *Terminal, buffer: *buf.Buffer, area: Area) !void {
        var attrs_buf = std.mem.zeroes([128]u8);
        var attrs_stream = std.io.fixedBufferStream(&attrs_buf);
        var attrs: []const u8 = undefined;
        var last_attrs_buf = std.mem.zeroes([128]u8);
        var last_attrs: ?[]const u8 = null;

        var span_index: usize = 0;
        for (@intCast(area.pos.row)..@as(usize, @intCast(area.pos.row)) + area.dims.height) |term_row| {
            const buffer_row = @as(i32, @intCast(term_row)) + buffer.offset.row;
            if (buffer_row < 0) continue;
            if (buffer_row >= buffer.line_positions.items.len) break;

            var byte: usize = if (buffer_row > 0) buffer.line_byte_positions.items[@intCast(buffer_row - 1)] else 0;
            var term_col: i32 = 0;

            var line = buffer.lineContent(@intCast(buffer_row));
            try self.moveCursor(.{ .row = @intCast(term_row), .col = area.pos.col });

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

            for (0..line.len + 1) |i| {
                const ch = if (i == line.len) ' ' else line[i];
                attrs_stream.reset();
                const buffer_col = @as(i32, @intCast(term_col)) + buffer.offset.col;

                if (term_col >= @as(i32, @intCast(area.dims.width))) break;
                if (buffer.ts_state) |ts_state| {
                    const highlight_spans = ts_state.highlight.spans.items;
                    const ch_attrs: []const co.Attr = b: while (span_index < highlight_spans.len) {
                        const span = highlight_spans[span_index];
                        if (span.span.start_byte > byte) break :b co.attributes.text;
                        if (byte >= span.span.start_byte and byte < span.span.end_byte) {
                            break :b span.attrs;
                        }
                        span_index += 1;
                    } else {
                        break :b co.attributes.text;
                    };
                    try co.attributes.write(ch_attrs, attrs_stream.writer());
                }

                if (buffer.selection) |selection| {
                    if (selection.inRange(.{ .row = buffer_row, .col = buffer_col })) {
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

        const buffer = main.editor.active_buffer;
        const replace_range = cmp_menu.replace_range.?;
        const menu_pos = (Cursor{
            .row = @intCast(replace_range.start.line),
            .col = @intCast(replace_range.start.character),
        })
            .applyOffset(buffer.offset.negate())
            .applyOffset(.{ .row = 1 });

        var longest_item: usize = 0;
        for (cmp_menu.display_items.items) |idx| {
            const cmp_item = cmp_menu.completion_items.items[idx];
            if (cmp_item.label.len > longest_item) longest_item = cmp_item.label.len;
        }
        const menu_width = @min(max_width, longest_item + 1);

        {
            try self.resetAttributes();

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

        {
            const cmp_item = cmp_menu.activeItem();
            if (cmp_item.detail == null and cmp_item.documentation == null) return;
            var doc_lines = std.ArrayList([]const u8).init(self.allocator);
            defer doc_lines.deinit();
            if (cmp_item.detail) |detail| try doc_lines.append(detail);
            if (cmp_item.documentation) |documentation| {
                var doc_iter = std.mem.splitScalar(u8, documentation, '\n');
                while (doc_iter.next()) |line| {
                    try doc_lines.append(line);
                }
            }

            const doc_pos = menu_pos.applyOffset(.{ .col = menu_width });
            try self.drawDocumentation(doc_lines.items, doc_pos);
        }
    }

    fn drawHover(self: *Terminal, text: []const u8) !void {
        var doc_lines = std.ArrayList([]const u8).init(self.allocator);
        defer doc_lines.deinit();
        var doc_iter = std.mem.splitScalar(u8, text, '\n');
        while (doc_iter.next()) |line| {
            try doc_lines.append(line);
        }
        const buffer = main.editor.active_buffer;
        const max_doc_width = 90;
        var longest_line: usize = 0;
        for (doc_lines.items) |line| {
            if (line.len > longest_line) longest_line = line.len;
        }
        var doc_pos = buffer.cursor.applyOffset(buffer.offset.negate()).applyOffset(.{ .row = 1 });
        const doc_width = @min(max_doc_width, longest_line);
        if (doc_pos.col + doc_width > self.dimensions.width) {
            doc_pos.col = @max(0, @as(i32, @intCast(self.dimensions.width)) - doc_width);
        }
        try self.drawDocumentation(doc_lines.items, doc_pos);
    }

    fn drawDocumentation(self: *Terminal, lines: []const []const u8, pos: Cursor) !void {
        try co.attributes.write(co.attributes.documentation_menu, self.writer.writer());
        defer self.resetAttributes() catch {};

        const max_doc_width = 90;
        var longest_line: usize = 0;
        for (lines) |line| {
            if (line.len > longest_line) longest_line = line.len;
        }
        const doc_width = @min(max_doc_width, longest_line);

        for (0..lines.len) |i| {
            const doc_line = lines[i];
            try self.moveCursor(.{
                .row = pos.row + @as(i32, @intCast(i)),
                .col = pos.col,
            });
            const available_len = @min(self.dimensions.width - @as(usize, @intCast(pos.col)), doc_width);
            const visible_len = @min(available_len, doc_line.len);
            try self.write(doc_line[0..visible_len]);
            for (0..available_len - visible_len) |_| {
                try self.write(" ");
            }
        }
    }

    fn drawMessage(self: *Terminal) !void {
        if (main.editor.message_read_idx == main.editor.messages.items.len) return;
        const message = main.editor.messages.items[main.editor.message_read_idx];
        const message_height = std.mem.count(u8, message, "\n") + 1;
        try self.moveCursor(.{ .row = @intCast(self.dimensions.height - message_height) });
        try co.attributes.write(co.attributes.message, self.writer.writer());
        try self.write(message);
        try self.resetAttributes();
    }

    fn drawCmd(self: *Terminal, command_line: *const cmd.CommandLine) !void {
        const last_row = self.dimensions.height - 1;
        const prefix = command_line.command.?.prefix();
        try self.moveCursor(.{ .row = @intCast(last_row) });
        try co.attributes.write(co.attributes.command_line, self.writer.writer());
        try self.write(prefix);
        for (command_line.content.items) |ch| {
            try self.format("{u}", .{ch});
        }
        try self.resetAttributes();
        try self.moveCursor(.{ .row = @intCast(last_row), .col = @intCast(prefix.len + command_line.cursor) });
    }
};

pub fn terminalSize() !Dimensions {
    var w: std.c.winsize = undefined;
    if (std.c.ioctl(main.std_out.handle, std.c.T.IOCGWINSZ, &w) == -1) {
        return error.TermSize;
    }
    return .{
        .width = w.col,
        .height = w.row,
    };
}

pub fn computeLayout(term_dims: Dimensions) Layout {
    const number_line_width = 5;

    return .{
        .number_line = .{
            .pos = .{},
            .dims = .{
                .height = term_dims.height,
                .width = number_line_width,
            },
        },
        .buffer = .{
            .pos = .{ .col = number_line_width },
            .dims = .{
                .height = term_dims.height,
                .width = term_dims.width - number_line_width,
            },
        },
    };
}

pub fn parseAnsi(allocator: Allocator, input: *std.ArrayList(u8)) !inp.Key {
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
    return key;
}

pub fn getCodes(allocator: Allocator) !?[]const u8 {
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

pub fn getKeys(allocator: Allocator, codes: []const u8) ![]inp.Key {
    var keys = std.ArrayList(inp.Key).init(allocator);

    var cs = std.ArrayList(u8).init(allocator);
    defer cs.deinit();
    try cs.appendSlice(codes);

    while (cs.items.len > 0) {
        const key = parseAnsi(allocator, &cs) catch |e| {
            log.debug(@This(), "{}\n", .{e});
            continue;
        };
        log.debug(@This(), "key: {}\n", .{key});
        try keys.append(key);
    }
    return try keys.toOwnedSlice();
}

fn ansiCodeToString(allocator: Allocator, code: u8) ![]const u8 {
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
