const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const main = @import("main.zig");
const edi = @import("editor.zig");
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
    /// Array list of array lists of utf8 codepoints
    content: std.ArrayList(std.ArrayList(u21)),
    content_raw: std.ArrayList(u8),
    spans: std.ArrayList(ts.SpanAttrsTuple),
    parser: ?*ts.ts.TSParser,
    query: ?*ts.ts.TSQuery,
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
            .content = std.ArrayList(std.ArrayList(u21)).init(allocator),
            .content_raw = raw,
            .spans = std.ArrayList(ts.SpanAttrsTuple).init(allocator),
            .parser = null,
            .query = null,
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
            const query_str = self.file_type.ts.?.highlight_query;
            var err: ts.ts.TSQueryError = undefined;
            self.query = ts.ts.ts_query_new(language(), query_str.ptr, @intCast(query_str.len), null, &err);
            if (err > 0) return error.Query;
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
        var lines_iter = std.mem.splitScalar(u8, self.content_raw.items, '\n');
        while (true) {
            const next: []u8 = @constCast(lines_iter.next() orelse break);
            const view = try std.unicode.Utf8View.init(next);
            var iter = view.iterator();
            var line = std.ArrayList(u21).init(self.allocator);
            while (iter.nextCodepoint()) |ch| {
                try line.append(ch);
            }
            try self.content.append(line);
        }
        if (self.content.getLastOrNull()) |last| {
            if (last.items.len == 0) {
                _ = self.content.orderedRemove(self.content.items.len - 1);
                last.deinit();
            }
        }
    }

    pub fn deinit(self: *Buffer) void {
        if (self.parser) |p| ts.ts.ts_parser_delete(p);
        if (self.tree) |t| ts.ts.ts_tree_delete(t);
        defer if (self.query) |query| ts.ts.ts_query_delete(query);
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
        self.scrollForCursor(new_buf_cursor);

        const term_cursor = new_buf_cursor.applyOffset(self.offset.negate());
        const dims = main.term.dimensions;
        const in_term = term_cursor.row >= 0 and term_cursor.row < dims.height and
            term_cursor.col >= 0 and term_cursor.col < dims.width;
        if (!in_term) return;

        if (new_buf_cursor.row > self.content.items.len - 1) return;
        const line = &self.content.items[@intCast(new_buf_cursor.row)];
        const max_col = line.items.len;
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
            main.editor.needs_redraw = true;
        } else {
            try self.clearSelection();
        }

        main.editor.needs_update_cursor = true;
    }

    test "moveCursor" {
        var buffer = try testSetup(
            \\abc
            \\def
            \\ghijk
        );
        defer buffer.deinit();

        try buffer.moveCursor(.{ .row = 0, .col = 1 });
        try testing.expectEqual(Cursor{ .row = 0, .col = 1 }, buffer.cursor);

        try buffer.moveCursor(Cursor{ .row = 2, .col = 2 });
        try testing.expectEqual(Cursor{ .row = 2, .col = 2 }, buffer.cursor);
    }

    pub fn enterMode(self: *Buffer, mode: edi.Mode) !void {
        if (main.editor.mode == mode) return;
        switch (mode) {
            .normal => {
                try self.clearSelection();
                try main.editor.completion_menu.reset();
                log.log(@This(), "mode: {}\n", .{main.editor.mode});
            },
            .select => {
                try self.selectChar();
            },
            .insert => {
                try self.clearSelection();
            },
        }
        main.editor.mode = mode;
        main.editor.needs_update_cursor = true;
    }

    /// TODO: search for next word in subsequent lines
    pub fn moveToNextWord(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const line = self.content.items[@intCast(self.cursor.row)];

        var col = self.cursor.col;
        while (col < line.items.len - 1) {
            const ch = line.items[@intCast(col)];
            const next = line.items[@intCast(col + 1)];
            if (std.meta.eql(boundary(ch, next), .wordStart)) {
                col += 1;
                break;
            }
            col += 1;
        } else {
            // no word found on this line
            return;
        }
        try self.moveCursor(.{ .row = self.cursor.row, .col = col });
        if (self.selection == null) {
            self.selection = .{ .start = old_cursor, .end = self.cursor };
            main.editor.needs_redraw = true;
        }
    }

    test "moveToNextWord plain words" {
        var buffer = try testSetup(
            \\one two three
        );
        defer buffer.deinit();

        buffer.cursor = .{ .row = 0, .col = 0 };
        try buffer.moveToNextWord();
        try testing.expectEqual(
            SelectionSpan{ .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 0, .col = 4 } },
            buffer.selection,
        );
    }

    test "moveToNextWord no move" {
        var buffer = try testSetup(
            \\one two three
        );
        defer buffer.deinit();

        buffer.cursor = .{ .row = 0, .col = 9 };
        try buffer.moveToNextWord();
        try testing.expectEqual(null, buffer.selection);
    }

    /// TODO: search for next word in preceding lines
    pub fn moveToPrevWord(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const line = self.content.items[@intCast(self.cursor.row)];

        var col = self.cursor.col;
        while (col > 0) {
            const ch = line.items[@intCast(col)];
            const next = line.items[@intCast(col - 1)];
            if (std.meta.eql(boundary(ch, next), .wordStart)) {
                col -= 1;
                break;
            }
            col -= 1;
        } else {
            // no word found on this line
            return;
        }
        try self.moveCursor(.{ .row = self.cursor.row, .col = col });
        if (self.selection == null) {
            self.selection = .{ .start = old_cursor, .end = self.cursor };
            main.editor.needs_redraw = true;
        }
    }

    pub fn insertText(self: *Buffer, text: []const u21) !void {
        for (text) |ch| {
            var line = &self.content.items[@intCast(self.cursor.row)];

            if (ch == '\n') {
                try self.insertNewline();
            } else {
                try line.insert(@intCast(self.cursor.col), ch);
                try self.moveCursor(self.cursor.applyOffset(.{ .row = 0, .col = 1 }));
            }
        }
        main.editor.needs_reparse = true;
    }

    pub fn insertNewline(self: *Buffer) !void {
        var line = try self.content.items[@intCast(self.cursor.row)].toOwnedSlice();
        defer self.allocator.free(line);
        try self.content.items[@intCast(self.cursor.row)].appendSlice(line[0..@intCast(self.cursor.col)]);
        var new_line = std.ArrayList(u21).init(main.allocator);
        try new_line.appendSlice(line[@intCast(self.cursor.col)..]);
        try self.content.insert(@intCast(self.cursor.row + 1), new_line);
        try self.moveCursor(.{ .row = self.cursor.row + 1, .col = 0 });
        main.editor.needs_reparse = true;
    }

    pub fn removeChar(self: *Buffer) !void {
        var line = &self.content.items[@intCast(self.cursor.row)];
        if (self.cursor.col == line.items.len) {
            if (self.cursor.row < self.content.items.len - 1) {
                try self.joinWithLineBelow(@intCast(self.cursor.row));
            } else {
                return;
            }
        } else {
            _ = line.orderedRemove(@intCast(self.cursor.col));
            main.editor.needs_reparse = true;
        }
    }

    pub fn removePrevChar(self: *Buffer) !void {
        var line = &self.content.items[@intCast(self.cursor.row)];
        if (self.cursor.col == 0) {
            if (self.cursor.row > 0) {
                const prev_line = &self.content.items[@intCast(self.cursor.row - 1)];
                try self.joinWithLineBelow(@intCast(self.cursor.row - 1));
                try self.moveCursor(.{ .row = self.cursor.row - 1, .col = @intCast(prev_line.items.len) });
            } else {
                return;
            }
        } else {
            try self.moveCursor(self.cursor.applyOffset(.{ .row = 0, .col = -1 }));
            _ = line.orderedRemove(@intCast(self.cursor.col));
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

    pub fn selectionDelete(self: *Buffer) !void {
        if (self.selection) |selection| {
            if (selection.end.row - selection.start.row > 1) {
                // remove fully selected lines
                try self.deleteLineRange(@intCast(selection.start.row + 1), @intCast(selection.end.row));
            }
            // start and end on separate lines
            if (selection.end.row - selection.start.row > 0) {
                try self.deleteToEnd(selection.start);
                const new_end: Cursor = .{ .row = selection.start.row + 1, .col = selection.end.col + 1 };
                try self.deleteToStart(new_end);
                try self.joinWithLineBelow(@intCast(selection.start.row));
            } else {
                var line = &self.content.items[@intCast(selection.start.row)];
                try line.replaceRange(
                    @intCast(selection.start.col),
                    @intCast(1 + selection.end.col - selection.start.col),
                    &[_]u21{},
                );
            }
            try self.moveCursor(selection.start);
            try self.enterMode(.normal);
            main.editor.needs_reparse = true;
        }
    }

    test "selectionDelete same line" {
        var buffer = try testSetup(
            \\abc
        );
        defer buffer.deinit();

        buffer.cursor = .{ .row = 0, .col = 1 };
        try buffer.enterMode(.select);
        try buffer.selectionDelete();

        try buffer.updateRaw();
        try testing.expectEqualStrings("ac", buffer.content_raw.items);
    }

    test "selectionDelete multiple lines" {
        var buffer = try testSetup(
            \\abc
            \\def
            \\ghijk
        );
        defer buffer.deinit();

        try buffer.moveCursor(.{ .row = 0, .col = 1 });
        try buffer.enterMode(.select);
        try buffer.moveCursor(Cursor{ .row = 2, .col = 2 });

        try testing.expectEqual(Cursor{ .row = 0, .col = 1 }, buffer.selection.?.start);
        try testing.expectEqual(Cursor{ .row = 2, .col = 2 }, buffer.selection.?.end);
        try buffer.selectionDelete();

        try buffer.updateRaw();
        try testing.expectEqualStrings("ajk", buffer.content_raw.items);
    }

    /// Delete every character from cursor (including) to the end of line
    pub fn deleteToEnd(self: *Buffer, cursor: Cursor) !void {
        var line = &self.content.items[@intCast(cursor.row)];
        try line.replaceRange(
            @intCast(cursor.col),
            line.items.len - @as(usize, @intCast(cursor.col)),
            &[_]u21{},
        );
        main.editor.needs_reparse = true;
    }

    /// Delete every character from start of line to cursor (excluding)
    pub fn deleteToStart(self: *Buffer, cursor: Cursor) !void {
        var line = &self.content.items[@intCast(cursor.row)];
        try line.replaceRange(
            0,
            @intCast(cursor.col),
            &[_]u21{},
        );
        main.editor.needs_reparse = true;
    }

    /// End is exclusive
    pub fn deleteLineRange(self: *Buffer, start: usize, end: usize) !void {
        if (end - start <= 0) return;
        for (start..end) |_| {
            const line = self.content.orderedRemove(start);
            line.deinit();
        }
        main.editor.needs_reparse = true;
    }

    pub fn clearSelection(self: *Buffer) !void {
        self.selection = null;
        main.editor.needs_redraw = true;
    }

    pub fn updateLinePositions(self: *Buffer) !void {
        self.line_positions.clearRetainingCapacity();
        var byte: usize = 0;
        for (0..self.content.items.len) |i| {
            try self.line_positions.append(byte);
            const line = &self.content.items[i];
            for (line.items) |ch| {
                byte += try std.unicode.utf8CodepointSequenceLength(ch);
            }
            // new line
            byte += 1;
        }
    }

    fn selectChar(self: *Buffer) !void {
        const pos = self.position();
        self.selection = .{ .start = pos, .end = pos };
        main.editor.needs_redraw = true;
    }

    pub fn textAt(self: *Buffer, range: lsp.types.Range) ![]const u21 {
        std.debug.assert(range.start.line == range.end.line);
        const line = &self.content.items[range.start.line];
        return line.items[range.start.character..range.end.character];
    }

    fn updateRaw(self: *Buffer) !void {
        self.content_raw.clearRetainingCapacity();
        if (self.content.items.len == 0) return;

        var b: [3]u8 = undefined;
        for (0..self.content.items.len) |i| {
            const line = &self.content.items[i];
            for (line.items) |ch| {
                const len = try std.unicode.utf8Encode(ch, &b);
                try self.content_raw.appendSlice(b[0..len]);
            }
            if (i != self.content.items.len - 1) {
                try self.content_raw.append('\n');
            }
        }
    }

    fn makeSpans(self: *Buffer) !void {
        if (self.tree == null) return;
        self.spans.clearRetainingCapacity();

        const cursor: *ts.ts.TSQueryCursor = ts.ts.ts_query_cursor_new().?;
        defer ts.ts.ts_query_cursor_delete(cursor);
        const root_node = ts.ts.ts_tree_root_node(self.tree);
        ts.ts.ts_query_cursor_exec(cursor, self.query.?, root_node);

        var match: ts.ts.TSQueryMatch = undefined;
        while (ts.ts.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |capture| {
                var capture_name_len: u32 = undefined;
                const capture_name = ts.ts.ts_query_capture_name_for_id(self.query.?, capture.index, &capture_name_len);
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
        const dims = main.term.dimensions;
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
            const line_len = line.items.len;
            if (new_buf_cursor.col <= line_len) {
                self.offset.col += 1 + term_cursor.col - @as(i32, @intCast(dims.width));
                main.editor.needs_redraw = true;
            }
        }
    }

    fn testSetup(content: []const u8) !Buffer {
        try main.testSetup();
        const allocator = std.testing.allocator;
        const buffer = try init(allocator, "test.txt", content);
        log.log(@This(), "created test buffer with content: \n{s}\n", .{content});
        return buffer;
    }

    test "test buffer" {
        var buffer = try testSetup(
            \\abc
        );
        defer buffer.deinit();

        try testing.expectEqualStrings("abc", buffer.content_raw.items);
    }
};

const Boundary = union(enum) {
    wordStart,
    wordEnd,

    /// 0: whitespace
    /// 1: symbols
    /// 2: alphabet
    fn rank(ch: u21) u8 {
        if (isWhitespace(ch)) return 0;
        if (isAlphabet(ch)) return 2;
        return 1;
    }
};

fn boundary(ch1: u21, ch2: u21) ?Boundary {
    const r1 = Boundary.rank(ch1);
    const r2 = Boundary.rank(ch2);
    switch (std.math.order(r1, r2)) {
        .eq => return null,
        .lt => return .wordStart,
        .gt => return .wordEnd,
    }
}

fn isAlphabet(ch: u21) bool {
    return (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch > 127;
}

fn isWhitespace(ch: u21) bool {
    // TODO: tabs, other
    return ch == ' ';
}
