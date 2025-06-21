const std = @import("std");
const dl = std.DynLib;
const testing = std.testing;
const assert = std.debug.assert;
const main = @import("main.zig");
const ft = @import("file_type.zig");
const ts = @import("ts.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");

pub const Cursor = struct {
    row: i32,
    col: i32,

    pub fn apply_offset(self: Cursor, offset: Cursor) Cursor {
        return .{ .row = self.row + offset.row, .col = self.col + offset.col };
    }

    pub fn negate(self: Cursor) Cursor {
        return .{
            .row = -self.row,
            .col = -self.col,
        };
    }

    pub fn order(self: Cursor, other: Cursor) std.math.Order {
        if (std.meta.eql(self, other)) return .eq;
        if (self.row == other.row) {
            return std.math.order(self.col, other.col);
        }
        return std.math.order(self.row, other.row);
    }

    pub fn from_lsp(position: lsp.types.Position) Cursor {
        return .{
            .row = @intCast(position.line),
            .col = @intCast(position.character),
        };
    }
};

pub const SelectionSpan = struct {
    start: Cursor,
    end: Cursor,

    pub fn in_range(self: SelectionSpan, pos: Cursor) bool {
        const start = self.start.order(pos);
        const end = self.end.order(pos);
        return start != .gt and end != .lt;
    }
};

pub const Buffer = struct {
    path: []const u8,
    uri: []const u8,
    content: BufferContent,
    content_raw: std.ArrayList(u8),
    spans: std.ArrayList(ts.SpanNodeTypeTuple),
    parser: ?*ts.ts.TSParser,
    tree: ?*ts.ts.TSTree,
    selection: ?SelectionSpan,
    diagnostics: std.ArrayList(lsp.types.Diagnostic),
    /// Cursor position in local buffer character space
    cursor: Cursor,
    /// How buffer is positioned relative to the window
    /// (0, 0) means Buffer.cursor is the same as window cursor
    offset: Cursor,
    line_positions: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, content_raw: []const u8) !Buffer {
        var raw = std.ArrayList(u8).init(allocator);
        try raw.appendSlice(content_raw);

        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{path});
        var buffer = Buffer{
            .path = path,
            .uri = uri,
            .content = std.ArrayList(Line).init(allocator),
            .content_raw = raw,
            .spans = std.ArrayList(ts.SpanNodeTypeTuple).init(allocator),
            .parser = null,
            .tree = null,
            .selection = null,
            .diagnostics = std.ArrayList(lsp.types.Diagnostic).init(allocator),
            .cursor = .{ .row = 0, .col = 0 },
            .offset = .{ .row = 0, .col = 0 },
            .line_positions = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
        try buffer.init_parser();
        try buffer.update_content();
        return buffer;
    }

    fn init_parser(self: *Buffer) !void {
        const file_ext = std.fs.path.extension(self.path);
        const file_type = ft.file_type.get(file_ext) orelse return;
        var language_lib = try dl.open(file_type.lib_path);
        var language: *const fn () *ts.ts.struct_TSLanguage = undefined;
        language = language_lib.lookup(@TypeOf(language), @ptrCast(file_type.lib_symbol)) orelse return error.NoSymbol;
        self.parser = ts.ts.ts_parser_new();
        _ = ts.ts.ts_parser_set_language(self.parser, language());
    }

    pub fn ts_parse(self: *Buffer) !void {
        try self.update_raw();
        if (self.parser == null) return;

        if (self.tree) |old_tree| ts.ts.ts_tree_delete(old_tree);
        self.tree = ts.ts.ts_parser_parse_string(
            self.parser,
            null,
            @ptrCast(self.content_raw.items),
            @intCast(self.content_raw.items.len),
        );
        if (main.log_enabled) {
            const node = ts.ts.ts_tree_root_node(self.tree);
            log.log(@This(), "tree: {s}\n", .{std.mem.span(ts.ts.ts_node_string(node))});
        }
        try self.make_spans();
    }

    pub fn update_content(self: *Buffer) !void {
        var lines_iter = std.mem.splitSequence(u8, self.content_raw.items, "\n");
        while (true) {
            const next: []u8 = @constCast(lines_iter.next() orelse break);
            var line = std.ArrayList(u8).init(self.allocator);
            try line.appendSlice(next);
            try self.content.append(line);
        }
    }

    pub fn deinit(self: *Buffer) void {
        if (self.parser) |p| ts.ts.ts_parser_delete(p);
        if (self.tree) |t| ts.ts.ts_tree_delete(t);
        for (self.content.items) |line| line.deinit();
        self.content.deinit();
        self.content_raw.deinit();
        self.spans.deinit();
        self.diagnostics.deinit();
        self.line_positions.deinit();
        self.allocator.free(self.uri);
    }

    /// Character position in buffer space
    pub fn position(self: *Buffer) Cursor {
        return .{
            .row = @intCast(self.cursor.row),
            .col = @intCast(self.cursor.col),
        };
    }

    pub fn inv_position(self: *Buffer, pos: Cursor) Cursor {
        _ = self;
        return .{
            .row = @intCast(pos.row),
            .col = @intCast(pos.col),
        };
    }

    pub fn move_cursor(self: *Buffer, new_buf_cursor: Cursor) !void {
        const old_position = self.position();

        if (new_buf_cursor.row < 0) return;
        const dims = try main.term.terminal_size();
        self.scroll_for_cursor(new_buf_cursor);

        const term_cursor = new_buf_cursor.apply_offset(self.offset.negate());
        const in_term = term_cursor.row >= 0 and term_cursor.row < dims.height and
            term_cursor.col >= 0 and term_cursor.col < dims.width;
        if (!in_term) return;

        if (new_buf_cursor.row >= self.content.items.len - 1) return;
        const line = &self.content.items[@intCast(new_buf_cursor.row)];
        const max_col = utf8_character_len(line.items) catch return;
        const col: i32 = @intCast(@min(new_buf_cursor.col, max_col));

        const valid_cursor = Cursor{
            .row = new_buf_cursor.row,
            .col = col,
        };

        log.log(@This(), "valid cursor, in buf: {}, in term: {}\n", .{ valid_cursor, term_cursor });
        self.scroll_for_cursor(valid_cursor);

        (&self.cursor).* = valid_cursor;
        if (main.editor.mode == .select) {
            const selection = &self.selection.?;
            const cursor_was_at_start = std.meta.eql(selection.start, old_position);
            if (cursor_was_at_start) {
                selection.start = self.position();
            } else {
                selection.end = self.position();
            }
            if (selection.start.order(selection.end) == .gt) {
                const tmp = selection.start;
                selection.start = selection.end;
                selection.end = tmp;
            }
        }
        main.editor.needs_redraw = true;
    }

    pub fn insert_text(self: *Buffer, text: []u8) !void {
        const view = try std.unicode.Utf8View.init(text);
        var iter = view.iterator();
        while (iter.nextCodepointSlice()) |ch| {
            const cbp = try self.cursor_byte_pos(self.cursor);
            var line = &self.content.items[@intCast(cbp.row)];

            if (std.mem.eql(u8, ch, "\n")) {
                try self.insert_newline();
            } else {
                try line.insertSlice(@intCast(cbp.col), ch);
                try self.move_cursor(self.cursor.apply_offset(.{.row = 0, .col = 1}));
            }
        }
        main.editor.needs_reparse = true;
    }

    pub fn insert_newline(self: *Buffer) !void {
        const cbp = try self.cursor_byte_pos(self.cursor);
        const row: usize = @intCast(cbp.row);
        var line = try self.content.items[row].toOwnedSlice();
        defer self.allocator.free(line);
        try self.content.items[row].appendSlice(line[0..@intCast(cbp.col)]);
        var new_line = std.ArrayList(u8).init(main.allocator);
        try new_line.appendSlice(line[@intCast(cbp.col)..]);
        try self.content.insert(@intCast(cbp.row + 1), new_line);
        try self.move_cursor(.{.row = self.cursor.row + 1, .col = 0});
        main.editor.needs_reparse = true;
    }

    pub fn remove_char(self: *Buffer) !void {
        const cbp = try self.cursor_byte_pos(self.cursor);
        var line = &self.content.items[@intCast(cbp.row)];
        if (self.cursor.col == try utf8_character_len(line.items)) {
            if (self.cursor.row < self.content.items.len - 1) {
                try self.join_with_line_below(@intCast(cbp.row));
            } else {
                return;
            }
        } else {
            _ = line.orderedRemove(@intCast(cbp.col));
            main.editor.needs_reparse = true;
        }
    }

    pub fn remove_prev_char(self: *Buffer) !void {
        const cbp = try self.cursor_byte_pos(self.cursor);
        var line = &self.content.items[@intCast(cbp.row)];
        if (cbp.col == 0) {
            if (self.cursor.row > 0) {
                const prev_line = &self.content.items[@intCast(cbp.row - 1)];
                const col = try utf8_character_len(prev_line.items);
                try self.join_with_line_below(@intCast(cbp.row - 1));
                try self.move_cursor(.{.row = self.cursor.row - 1, .col = @intCast(col)});
            } else {
                return;
            }
        } else {
            try self.move_cursor(self.cursor.apply_offset(.{.row = 0, .col = -1}));
            const col_byte = try utf8_byte_pos(line.items, @intCast(self.cursor.col));
            _ = line.orderedRemove(col_byte);
            main.editor.needs_reparse = true;
        }
    }

    pub fn join_with_line_below(self: *Buffer, row: usize) !void {
        var line = &self.content.items[row];
        var next_line = self.content.orderedRemove(row + 1);
        defer next_line.deinit();
        try line.appendSlice(next_line.items);
        main.editor.needs_reparse = true;
    }

    pub fn select_char(self: *Buffer) !void {
        const pos = self.position();
        self.selection = .{ .start = pos, .end = pos };
    }

    pub fn update_line_positions(self: *Buffer) !void {
        self.line_positions.clearRetainingCapacity();
        var byte: usize = 0;
        for (0..self.content.items.len) |i| {
            try self.line_positions.append(byte);
            const line = &self.content.items[i];
            const line_view = try std.unicode.Utf8View.init(line.items);
            var line_iter = line_view.iterator();
            while (line_iter.nextCodepoint()) |ch| {
                byte += try std.unicode.utf8CodepointSequenceLength(ch);
            }
            // new line
            byte += 1;
        }
    }

    fn cursor_byte_pos(self: *Buffer, cursor: Cursor) !Cursor {
        if (cursor.row < 0 or cursor.col < 0) return error.OutOfBounds;
        if (cursor.row >= self.content.items.len) return error.OutOfBounds;
        const line = &self.content.items[@intCast(cursor.row)];
        const col = try utf8_byte_pos(line.items, @intCast(cursor.col));
        return .{
            .row = cursor.row,
            .col = @intCast(col),
        };
    }

    fn update_raw(self: *Buffer) !void {
        self.content_raw.clearRetainingCapacity();
        for (self.content.items) |line| {
            try self.content_raw.appendSlice(line.items);
            try self.content_raw.append('\n');
        }
    }

    fn make_spans(self: *Buffer) !void {
        if (self.tree == null) return;
        self.spans.clearRetainingCapacity();

        const root_node = ts.ts.ts_tree_root_node(self.tree);
        var tree_cursor = ts.ts.ts_tree_cursor_new(root_node);
        var node = root_node;

        traverse: while (true) {
            const node_type = std.mem.span(ts.ts.ts_node_type(node));
            if (node_type.len == 0) continue;

            const start_byte = ts.ts.ts_node_start_byte(node);
            const end_byte = ts.ts.ts_node_end_byte(node);
            try self.spans.append(.{
                .span = .{ .start_byte = start_byte, .end_byte = end_byte },
                .node_type = @constCast(node_type),
            });

            if (ts.ts.ts_tree_cursor_goto_first_child(&tree_cursor)) {
                node = ts.ts.ts_tree_cursor_current_node(&tree_cursor);
            } else {
                while (true) {
                    if (ts.ts.ts_tree_cursor_goto_next_sibling(&tree_cursor)) {
                        node = ts.ts.ts_tree_cursor_current_node(&tree_cursor);
                        break;
                    } else {
                        if (ts.ts.ts_tree_cursor_goto_parent(&tree_cursor)) {
                            node = ts.ts.ts_tree_cursor_current_node(&tree_cursor);
                        } else {
                            break :traverse;
                        }
                    }
                }
            }
        }
    }

    fn scroll_for_cursor(self: *Buffer, new_buf_cursor: Cursor) void {
        const term_cursor = new_buf_cursor.apply_offset(self.offset.negate());
        const dims = main.term.terminal_size() catch unreachable;
        if (term_cursor.row < 0 and new_buf_cursor.row >= 0) {
            self.offset.row += term_cursor.row;
            main.editor.needs_redraw = true;
        }
        if (term_cursor.row >= dims.height and new_buf_cursor.row < self.content.items.len - 1) {
            self.offset.row += 1 + term_cursor.row - @as(i32, @intCast(dims.height));
            main.editor.needs_redraw = true;
        }
        if (term_cursor.col < 0 and new_buf_cursor.col >= 0) {
            self.offset.col += term_cursor.col;
            main.editor.needs_redraw = true;
        }
        if (term_cursor.col >= dims.width and new_buf_cursor.row >= 0 and new_buf_cursor.row < self.content.items.len - 1) {
            const line = &self.content.items[@intCast(new_buf_cursor.row)];
            const line_len = utf8_character_len(line.items) catch return;
            if (new_buf_cursor.col <= line_len) {
                self.offset.col += 1 + term_cursor.col - @as(i32, @intCast(dims.width));
                main.editor.needs_redraw = true;
            }
        }
    }

    fn test_setup(content: []const u8) !Buffer {
        try main.testing_setup();
        const allocator = std.testing.allocator;
        const buffer = try init(allocator, "test.txt", content);
        return buffer;
    }

    test "test buffer" {
        var buffer = try test_setup("");
        defer buffer.deinit();

        try testing.expectEqualSlices(u8, buffer.content_raw.items, "");
    }
};

pub const BufferContent = std.ArrayList(Line);

pub const Line = std.ArrayList(u8);

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

/// Find UTF-8 byte string length in characters
fn utf8_character_len(str: []u8) !usize {
    const view = try std.unicode.Utf8View.init(str);
    var iter = view.iterator();
    var len: usize = 0;
    while (iter.nextCodepointSlice()) |_| len += 1;
    return len;
}
