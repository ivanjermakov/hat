const std = @import("std");
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

    pub fn applyOffset(self: Cursor, offset: Cursor) Cursor {
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

    pub fn fromLsp(position: lsp.types.Position) Cursor {
        return .{
            .row = @intCast(position.line),
            .col = @intCast(position.character),
        };
    }
};

pub const SelectionSpan = struct {
    start: Cursor,
    end: Cursor,

    pub fn inRange(self: SelectionSpan, pos: Cursor) bool {
        const start = self.start.order(pos);
        const end = self.end.order(pos);
        return start != .gt and end != .lt;
    }
};

pub const Buffer = struct {
    path: []const u8,
    uri: []const u8,
    file_type: ft.FileTypeConfig,
    content: BufferContent,
    content_raw: std.ArrayList(u8),
    spans: std.ArrayList(ts.SpanAttrsTuple),
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

        const file_ext = std.fs.path.extension(path);
        const file_type = ft.file_type.get(file_ext) orelse ft.plain;

        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{path});
        var buffer = Buffer{
            .path = path,
            .file_type = file_type,
            .uri = uri,
            .content = std.ArrayList(Line).init(allocator),
            .content_raw = raw,
            .spans = std.ArrayList(ts.SpanAttrsTuple).init(allocator),
            .parser = null,
            .tree = null,
            .selection = null,
            .diagnostics = std.ArrayList(lsp.types.Diagnostic).init(allocator),
            .cursor = .{ .row = 0, .col = 0 },
            .offset = .{ .row = 0, .col = 0 },
            .line_positions = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
        try buffer.initParser();
        try buffer.updateContent();
        return buffer;
    }

    fn initParser(self: *Buffer) !void {
        if (self.file_type.ts) |ts_conf| {
            const language = try ts_conf.loadLanguage();
            self.parser = ts.ts.ts_parser_new();
            _ = ts.ts.ts_parser_set_language(self.parser, language());
        }
    }

    pub fn tsParse(self: *Buffer) !void {
        try self.updateRaw();
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
        try self.makeSpans();
    }

    pub fn updateContent(self: *Buffer) !void {
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

    pub fn moveCursor(self: *Buffer, new_buf_cursor: Cursor) !void {
        const old_position = self.position();

        if (new_buf_cursor.row < 0) return;
        const dims = try main.term.terminalSize();
        self.scrollForCursor(new_buf_cursor);

        const term_cursor = new_buf_cursor.applyOffset(self.offset.negate());
        const in_term = term_cursor.row >= 0 and term_cursor.row < dims.height and
            term_cursor.col >= 0 and term_cursor.col < dims.width;
        if (!in_term) return;

        if (new_buf_cursor.row >= self.content.items.len - 1) return;
        const line = &self.content.items[@intCast(new_buf_cursor.row)];
        const max_col = utf8CharacterLen(line.items) catch return;
        const col: i32 = @intCast(@min(new_buf_cursor.col, max_col));

        const valid_cursor = Cursor{
            .row = new_buf_cursor.row,
            .col = col,
        };

        self.scrollForCursor(valid_cursor);

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
        main.editor.needs_update_cursor = true;
    }

    pub fn insertText(self: *Buffer, text: []u8) !void {
        const view = try std.unicode.Utf8View.init(text);
        var iter = view.iterator();
        while (iter.nextCodepointSlice()) |ch| {
            const cbp = try self.cursorBytePos(self.cursor);
            var line = &self.content.items[@intCast(cbp.row)];

            if (std.mem.eql(u8, ch, "\n")) {
                try self.insertNewline();
            } else {
                try line.insertSlice(@intCast(cbp.col), ch);
                try self.moveCursor(self.cursor.applyOffset(.{ .row = 0, .col = 1 }));
            }
        }
        main.editor.needs_reparse = true;
    }

    pub fn insertNewline(self: *Buffer) !void {
        const cbp = try self.cursorBytePos(self.cursor);
        const row: usize = @intCast(cbp.row);
        var line = try self.content.items[row].toOwnedSlice();
        defer self.allocator.free(line);
        try self.content.items[row].appendSlice(line[0..@intCast(cbp.col)]);
        var new_line = std.ArrayList(u8).init(main.allocator);
        try new_line.appendSlice(line[@intCast(cbp.col)..]);
        try self.content.insert(@intCast(cbp.row + 1), new_line);
        try self.moveCursor(.{ .row = self.cursor.row + 1, .col = 0 });
        main.editor.needs_reparse = true;
    }

    pub fn removeChar(self: *Buffer) !void {
        const cbp = try self.cursorBytePos(self.cursor);
        var line = &self.content.items[@intCast(cbp.row)];
        if (self.cursor.col == try utf8CharacterLen(line.items)) {
            if (self.cursor.row < self.content.items.len - 1) {
                try self.joinWithLineBelow(@intCast(cbp.row));
            } else {
                return;
            }
        } else {
            _ = line.orderedRemove(@intCast(cbp.col));
            main.editor.needs_reparse = true;
        }
    }

    pub fn removePrevChar(self: *Buffer) !void {
        const cbp = try self.cursorBytePos(self.cursor);
        var line = &self.content.items[@intCast(cbp.row)];
        if (cbp.col == 0) {
            if (self.cursor.row > 0) {
                const prev_line = &self.content.items[@intCast(cbp.row - 1)];
                const col = try utf8CharacterLen(prev_line.items);
                try self.joinWithLineBelow(@intCast(cbp.row - 1));
                try self.moveCursor(.{ .row = self.cursor.row - 1, .col = @intCast(col) });
            } else {
                return;
            }
        } else {
            try self.moveCursor(self.cursor.applyOffset(.{ .row = 0, .col = -1 }));
            const col_byte = try utf8BytePos(line.items, @intCast(self.cursor.col));
            _ = line.orderedRemove(col_byte);
            main.editor.needs_reparse = true;
        }
    }

    pub fn joinWithLineBelow(self: *Buffer, row: usize) !void {
        var line = &self.content.items[row];
        var next_line = self.content.orderedRemove(row + 1);
        defer next_line.deinit();
        try line.appendSlice(next_line.items);
        main.editor.needs_reparse = true;
    }

    pub fn selectChar(self: *Buffer) !void {
        const pos = self.position();
        self.selection = .{ .start = pos, .end = pos };
    }

    pub fn updateLinePositions(self: *Buffer) !void {
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

    pub fn textAt(self: *Buffer, range: lsp.types.Range) ![]const u8 {
        std.debug.assert(range.start.line == range.end.line);
        const line = &self.content.items[range.start.line];
        return line.items[range.start.character..range.end.character];
    }

    fn cursorBytePos(self: *Buffer, cursor: Cursor) !Cursor {
        if (cursor.row < 0 or cursor.col < 0) return error.OutOfBounds;
        if (cursor.row >= self.content.items.len) return error.OutOfBounds;
        const line = &self.content.items[@intCast(cursor.row)];
        const col = try utf8BytePos(line.items, @intCast(cursor.col));
        return .{
            .row = cursor.row,
            .col = @intCast(col),
        };
    }

    fn updateRaw(self: *Buffer) !void {
        self.content_raw.clearRetainingCapacity();
        for (self.content.items) |line| {
            try self.content_raw.appendSlice(line.items);
            try self.content_raw.append('\n');
        }
    }

    fn makeSpans(self: *Buffer) !void {
        if (self.tree == null) return;
        self.spans.clearRetainingCapacity();

        var err: ts.ts.TSQueryError = undefined;
        const language = ts.ts.ts_parser_language(self.parser).?;
        const query_str = self.file_type.ts.?.highlight_query;
        const query = ts.ts.ts_query_new(language, query_str.ptr, @intCast(query_str.len), null, &err);
        defer ts.ts.ts_query_delete(query);
        if (err > 0) return error.Query;

        const cursor: *ts.ts.TSQueryCursor = ts.ts.ts_query_cursor_new().?;
        defer ts.ts.ts_query_cursor_delete(cursor);
        const root_node = ts.ts.ts_tree_root_node(self.tree);
        ts.ts.ts_query_cursor_exec(cursor, query, root_node);

        var match: ts.ts.TSQueryMatch = undefined;
        while (ts.ts.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |capture| {
                var capture_name_len: u32 = undefined;
                const capture_name = ts.ts.ts_query_capture_name_for_id(query, capture.index, &capture_name_len);
                const node_type = capture_name[0..capture_name_len];
                const span: ts.Span = .{
                    .start_byte = ts.ts.ts_node_start_byte(capture.node),
                    .end_byte = ts.ts.ts_node_end_byte(capture.node),
                };
                try self.spans.append(ts.SpanAttrsTuple.init(span, node_type));
            }
        }
    }

    fn scrollForCursor(self: *Buffer, new_buf_cursor: Cursor) void {
        const term_cursor = new_buf_cursor.applyOffset(self.offset.negate());
        const dims = main.term.terminalSize() catch unreachable;
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
            const line_len = utf8CharacterLen(line.items) catch return;
            if (new_buf_cursor.col <= line_len) {
                self.offset.col += 1 + term_cursor.col - @as(i32, @intCast(dims.width));
                main.editor.needs_redraw = true;
            }
        }
    }

    fn testSetup(content: []const u8) !Buffer {
        try main.testingSetup();
        const allocator = std.testing.allocator;
        const buffer = try init(allocator, "test.txt", content);
        return buffer;
    }

    test "test buffer" {
        var buffer = try testSetup("");
        defer buffer.deinit();

        try testing.expectEqualSlices(u8, buffer.content_raw.items, "");
    }
};

pub const BufferContent = std.ArrayList(Line);

pub const Line = std.ArrayList(u8);

/// Find a byte position of a codepoint at cp_index in a UTF-8 byte string
fn utf8BytePos(str: []u8, cp_index: usize) !usize {
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
fn utf8CharacterLen(str: []u8) !usize {
    const view = try std.unicode.Utf8View.init(str);
    var iter = view.iterator();
    var len: usize = 0;
    while (iter.nextCodepointSlice()) |_| len += 1;
    return len;
}
