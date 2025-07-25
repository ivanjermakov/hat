const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const main = @import("main.zig");
const edi = @import("editor.zig");
const ft = @import("file_type.zig");
const ts = @import("ts.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const cha = @import("change.zig");
const uni = @import("unicode.zig");
const ter = @import("terminal.zig");
const clp = @import("clipboard.zig");

pub const Cursor = struct {
    row: i32 = 0,
    col: i32 = 0,

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

    pub fn toLsp(self: Cursor) lsp.types.Position {
        return .{
            .line = @intCast(self.row),
            .character = @intCast(self.col),
        };
    }
};

pub const Span = struct {
    start: Cursor,
    end: Cursor,

    pub fn inRange(self: Span, pos: Cursor) bool {
        const start = self.start.order(pos);
        const end = self.end.order(pos);
        return start != .gt and end == .gt;
    }

    pub fn inRangeInclusive(self: Span, pos: Cursor) bool {
        const start = self.start.order(pos);
        const end = self.end.order(pos);
        return start != .gt and end != .lt;
    }

    pub fn fromLsp(position: lsp.types.Range) Span {
        return .{
            .start = Cursor.fromLsp(position.start),
            .end = Cursor.fromLsp(position.end),
        };
    }

    pub fn toLsp(self: Span) lsp.types.Range {
        return .{
            .start = self.start.toLsp(),
            .end = self.end.toLsp(),
        };
    }

    pub fn toExclusiveEnd(self: Span, last_line_len: usize) Span {
        var span = self;
        if (self.end.col == last_line_len) {
            span.end = .{ .row = self.end.row + 1, .col = 0 };
        } else {
            span.end = span.end.applyOffset(.{ .col = 1 });
        }
        return span;
    }
};

pub const Buffer = struct {
    path: []const u8,
    uri: []const u8,
    /// Incremented on every content change
    version: usize = 0,
    file_type: ft.FileTypeConfig,
    /// Array list of array lists of utf8 codepoints
    content: std.ArrayList(std.ArrayList(u21)),
    content_raw: std.ArrayList(u8),
    ts_state: ?ts.State = null,
    /// End is inclusive
    selection: ?Span = null,
    diagnostics: std.ArrayList(lsp.types.Diagnostic),
    /// Cursor position in local buffer character space
    cursor: Cursor = .{},
    /// Cursor's preferred col
    /// Used to keep col when moving through variable-with lines
    cursor_desired_col: ?usize = null,
    /// How buffer is positioned relative to the window
    /// (0, 0) means Buffer.cursor is the same as window cursor
    offset: Cursor = .{},
    line_positions: std.ArrayList(usize),
    /// Indent depth for each line
    indents: std.ArrayList(usize),
    history: std.ArrayList(std.ArrayList(cha.Change)),
    history_index: ?usize = null,
    /// History index of the last file save
    /// Used to decide whether buffer has unsaved changes
    file_history_index: ?usize = null,
    /// Changes needed to be sent to LSP clients
    pending_changes: std.ArrayList(cha.Change),
    /// Changes yet to become a part of Buffer.history
    uncommitted_changes: std.ArrayList(cha.Change),
    lsp_connections: std.ArrayList(*lsp.LspConnection),
    scratch: bool = false,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: ?[]const u8, content_raw: []const u8) !Buffer {
        var raw = std.ArrayList(u8).init(allocator);
        try raw.appendSlice(content_raw);

        const scratch = path == null;
        const buf_path = if (path) |p|
            try allocator.dupe(u8, p)
        else
            try std.fmt.allocPrint(allocator, "scratch{d:0>2}", .{nextScratchId()});
        const file_ext = std.fs.path.extension(buf_path);
        const file_type = ft.file_type.get(file_ext) orelse ft.plain;

        const abs_path = std.fs.realpathAlloc(allocator, buf_path) catch null;
        defer if (abs_path) |a| allocator.free(a);
        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path orelse buf_path});
        var self = Buffer{
            .path = buf_path,
            .file_type = file_type,
            .uri = uri,
            .content = std.ArrayList(std.ArrayList(u21)).init(allocator),
            .content_raw = raw,
            .diagnostics = std.ArrayList(lsp.types.Diagnostic).init(allocator),
            .line_positions = std.ArrayList(usize).init(allocator),
            .indents = std.ArrayList(usize).init(allocator),
            .history = std.ArrayList(std.ArrayList(cha.Change)).init(allocator),
            .pending_changes = std.ArrayList(cha.Change).init(allocator),
            .uncommitted_changes = std.ArrayList(cha.Change).init(allocator),
            .lsp_connections = std.ArrayList(*lsp.LspConnection).init(allocator),
            .scratch = scratch,
            .allocator = allocator,
        };
        try self.updateContent();
        try self.updateLinePositions();
        if (self.file_type.ts) |ts_conf| {
            self.ts_state = try ts.State.init(allocator, ts_conf);
        }
        try self.reparse();
        return self;
    }

    pub fn reparse(self: *Buffer) !void {
        try self.updateRaw();
        if (self.ts_state) |*ts_state| try ts_state.reparse(self.content_raw.items);
        try self.updateLinePositions();
        try self.updateIndents();
    }

    pub fn updateContent(self: *Buffer) !void {
        var lines_iter = std.mem.splitScalar(u8, self.content_raw.items, '\n');
        while (true) {
            const next: []const u8 = @constCast(lines_iter.next() orelse break);
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
        for (self.lsp_connections.items) |conn| {
            conn.didClose(self) catch {};
        }
        self.lsp_connections.deinit();

        self.allocator.free(self.uri);
        self.allocator.free(self.path);

        if (self.ts_state) |*ts_state| ts_state.deinit();

        for (self.content.items) |line| line.deinit();
        self.content.deinit();
        self.content_raw.deinit();

        self.diagnostics.deinit();
        self.line_positions.deinit();
        self.indents.deinit();

        for (self.history.items) |*i| {
            for (i.items) |*c| c.deinit();
            i.deinit();
        }
        self.history.deinit();

        for (self.pending_changes.items) |*c| c.deinit();
        self.pending_changes.deinit();
        self.uncommitted_changes.deinit();
    }

    pub fn write(self: *Buffer) !void {
        try self.updateRaw();

        const file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(self.content_raw.items);

        self.file_history_index = self.history_index;

        const msg = try std.fmt.allocPrint(
            self.allocator,
            "{s} {}B written",
            .{ self.path, self.content_raw.items.len },
        );
        defer self.allocator.free(msg);
        try main.editor.sendMessage(msg);
    }

    pub fn moveCursor(self: *Buffer, new_cursor: Cursor) !void {
        const old_cursor = self.cursor;
        const vertical_only = old_cursor.col == new_cursor.col and old_cursor.row != new_cursor.row;

        if (new_cursor.row < 0) return;
        self.scrollForCursor(new_cursor);

        const term_cursor = new_cursor.applyOffset(self.offset.negate());
        const dims = main.term.dimensions;
        const in_term = term_cursor.row >= 0 and term_cursor.row < dims.height and
            term_cursor.col >= 0 and term_cursor.col < dims.width;
        if (!in_term) return;

        if (new_cursor.row + 1 > self.content.items.len) return;
        const line = &self.content.items[@intCast(new_cursor.row)];
        const max_col = line.items.len;
        var col: i32 = @intCast(@min(new_cursor.col, max_col));
        if (vertical_only) {
            if (self.cursor_desired_col) |desired| {
                col = @intCast(@min(desired, max_col));
            }
        }
        if (!vertical_only) {
            self.cursor_desired_col = @intCast(col);
        }

        const valid_cursor = Cursor{
            .row = new_cursor.row,
            .col = col,
        };

        self.scrollForCursor(valid_cursor);

        (&self.cursor).* = valid_cursor;

        switch (main.editor.mode) {
            .select => {
                const selection = &self.selection.?;
                const cursor_was_at_start = std.meta.eql(selection.start, old_cursor);
                if (cursor_was_at_start) {
                    selection.start = self.cursor;
                } else {
                    selection.end = self.cursor;
                }
                if (selection.start.order(selection.end) == .gt) {
                    const tmp = selection.start;
                    selection.start = selection.end;
                    selection.end = tmp;
                }
                main.editor.dirty.draw = true;
            },
            .select_line => {
                var selection = &self.selection.?;
                const move_start = selection.start.row == old_cursor.row and
                    (selection.end.row != old_cursor.row or self.cursor.row < selection.start.row);
                if (move_start) {
                    selection.start = .{ .row = self.cursor.row, .col = 0 };
                    const last_line = self.content.items[@intCast(selection.end.row)].items;
                    selection.end.col = @intCast(last_line.len);
                } else {
                    selection.start.col = 0;
                    selection.end.row = self.cursor.row;
                    const last_line = self.content.items[@intCast(selection.end.row)].items;
                    selection.end.col = @intCast(last_line.len);
                }
                main.editor.dirty.draw = true;
            },
            else => {
                try self.clearSelection();
            },
        }

        main.editor.dirty.cursor = true;
        main.editor.resetHover();
    }

    test "moveCursor" {
        var buffer = try testSetup(
            \\abc
            \\def
            \\ghijk
        );
        defer buffer.deinit();

        try buffer.moveCursor(.{ .col = 1 });
        try testing.expectEqual(Cursor{ .col = 1 }, buffer.cursor);

        try buffer.moveCursor(Cursor{ .row = 2, .col = 2 });
        try testing.expectEqual(Cursor{ .row = 2, .col = 2 }, buffer.cursor);
    }

    pub fn centerCursor(self: *Buffer) !void {
        const old_offset_row = self.offset.row;
        const dims = main.term.dimensions;
        const target_row: i32 = @intCast(@divFloor(dims.height, 2));
        const term_row = self.cursor.applyOffset(self.offset.negate()).row;
        self.offset.row = @max(0, self.offset.row + term_row - target_row);
        if (old_offset_row == self.offset.row) return;
        main.editor.dirty.draw = true;
    }

    /// TODO: search for next word in subsequent lines
    pub fn moveToNextWord(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const line = self.content.items[@intCast(self.cursor.row)];

        if (nextWordStart(line.items, @intCast(self.cursor.col))) |col| {
            try self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
            if (self.selection == null) {
                self.selection = .{ .start = old_cursor, .end = self.cursor };
                main.editor.dirty.draw = true;
            }
            main.editor.dotRepeatInside();
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
            Span{ .start = .{}, .end = .{ .col = 4 } },
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

        var col: usize = 0;
        while (col < self.cursor.col) {
            if (nextWordStart(line.items, col)) |word_start| {
                if (word_start >= self.cursor.col) break;
                col = word_start;
            }
        } else {
            return;
        }
        try self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
        if (self.selection == null) {
            self.selection = .{ .start = old_cursor, .end = self.cursor };
            main.editor.dirty.draw = true;
        }
        main.editor.dotRepeatInside();
    }

    /// TODO: search for next word in subsequent lines
    pub fn moveToWordEnd(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const line = self.content.items[@intCast(self.cursor.row)];

        if (wordEnd(line.items, @intCast(self.cursor.col + 1))) |col| {
            try self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
            if (self.selection == null) {
                self.selection = .{ .start = old_cursor, .end = self.cursor };
                main.editor.dirty.draw = true;
            }
            main.editor.dotRepeatInside();
        }
    }

    pub fn moveToTokenEnd(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const line = self.content.items[@intCast(self.cursor.row)];

        if (tokenEnd(line.items, @intCast(self.cursor.col + 1))) |col| {
            try self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
            if (self.selection == null) {
                self.selection = .{ .start = old_cursor, .end = self.cursor };
                main.editor.dirty.draw = true;
            }
            main.editor.dotRepeatInside();
        }
    }

    pub fn appendChange(self: *Buffer, change: *cha.Change) !void {
        try self.applyChange(change);
        try self.uncommitted_changes.append(change.*);
        try self.pending_changes.append(try change.clone(self.allocator));
    }

    pub fn commitChanges(self: *Buffer) !void {
        if (self.uncommitted_changes.items.len == 0) {
            log.log(@This(), "no changes to commit\n", .{});
            return;
        }
        log.log(@This(), "commit {} changes\n", .{self.uncommitted_changes.items.len});
        // history overwrite
        if ((self.history_index orelse 0) + 1 != self.history.items.len) {
            const i = self.history_index orelse 0;
            for (self.history.items[i..]) |*ch| ch.deinit();
            try self.history.replaceRange(i, self.history.items.len - i, &.{});
        }
        var new_hist = try std.ArrayList(cha.Change).initCapacity(self.allocator, 1);
        try new_hist.appendSlice(self.uncommitted_changes.items);
        self.uncommitted_changes.clearRetainingCapacity();
        try self.history.append(new_hist);
        self.history_index = self.history.items.len - 1;

        try main.editor.dotRepeatCommitReady();
    }

    pub fn changeInsertText(self: *Buffer, text: []const u21) !void {
        var change = try cha.Change.initInsert(
            self.allocator,
            .{ .start = self.cursor, .end = self.cursor },
            text,
        );
        try self.appendChange(&change);
    }

    pub fn changeDeleteChar(self: *Buffer) !void {
        var span: Span = .{ .start = self.cursor, .end = self.cursor.applyOffset(.{ .col = 1 }) };
        const line = self.content.items[@intCast(self.cursor.row)];
        if (self.cursor.col == line.items.len) {
            span.end = .{ .row = self.cursor.row + 1, .col = 0 };
        }
        const text = try self.textAt(self.allocator, span);
        defer self.allocator.free(text);
        var change = try cha.Change.initDelete(self.allocator, span, text);
        try self.appendChange(&change);
    }

    pub fn changeDeletePrevChar(self: *Buffer) !void {
        if (self.cursor.col == 0) {
            if (self.cursor.row > 0) {
                try self.changeJoinWithLineBelow(@intCast(self.cursor.row - 1));
            } else {
                return;
            }
        } else {
            const span: Span = .{ .start = self.cursor.applyOffset(.{ .col = -1 }), .end = self.cursor };
            const text = try self.textAt(self.allocator, span);
            defer self.allocator.free(text);
            var change = try cha.Change.initDelete(self.allocator, span, text);
            try self.appendChange(&change);
        }
    }

    pub fn changeJoinWithLineBelow(self: *Buffer, row: usize) !void {
        const line = &self.content.items[row];
        const span: Span = .{
            .start = .{ .row = @intCast(row), .col = @intCast(line.items.len) },
            .end = .{ .row = @intCast(row + 1), .col = 0 },
        };
        const text = try self.textAt(self.allocator, span);
        defer self.allocator.free(text);
        var change = try cha.Change.initDelete(self.allocator, span, text);
        try self.appendChange(&change);
        try self.commitChanges();
    }

    pub fn changeSelectionDelete(self: *Buffer) !void {
        if (self.selection) |selection| {
            const last_line = self.content.items[@intCast(selection.end.row)].items;
            const span = selection.toExclusiveEnd(last_line.len);
            try main.editor.enterMode(.normal);
            const text = try self.textAt(self.allocator, span);
            defer self.allocator.free(text);
            var change = try cha.Change.initDelete(self.allocator, span, text);
            try self.appendChange(&change);
        }
    }

    test "changeSelectionDelete same line" {
        var buffer = try testSetup(
            \\abc
        );
        defer buffer.deinit();

        buffer.cursor = .{ .row = 0, .col = 1 };
        try main.editor.enterMode(.select);
        try buffer.changeSelectionDelete();

        try buffer.commitChanges();
        try buffer.updateRaw();
        try testing.expectEqualStrings("ac", buffer.content_raw.items);
    }

    test "changeSelectionDelete line to end" {
        var buffer = try testSetup(
            \\abc
            \\def
        );
        defer buffer.deinit();

        try buffer.moveCursor(.{ .row = 0, .col = 1 });
        try main.editor.enterMode(.select);
        try buffer.moveCursor(.{ .row = 0, .col = 3 });
        try buffer.changeSelectionDelete();

        try buffer.commitChanges();
        try buffer.updateRaw();
        try testing.expectEqualStrings("adef", buffer.content_raw.items);
    }

    test "changeSelectionDelete multiple lines" {
        var buffer = try testSetup(
            \\abc
            \\def
            \\ghijk
        );
        defer buffer.deinit();

        try buffer.moveCursor(.{ .row = 0, .col = 1 });
        try main.editor.enterMode(.select);
        try buffer.moveCursor(Cursor{ .row = 2, .col = 2 });

        try testing.expectEqual(Cursor{ .row = 0, .col = 1 }, buffer.selection.?.start);
        try testing.expectEqual(Cursor{ .row = 2, .col = 2 }, buffer.selection.?.end);
        try buffer.changeSelectionDelete();

        try buffer.commitChanges();
        try buffer.updateRaw();
        try testing.expectEqualStrings("ajk", buffer.content_raw.items);
    }

    pub fn changeInsertLineBelow(self: *Buffer, row: i32) !void {
        const pos: Cursor = .{ .row = row + 1, .col = 0 };
        const span: Span = .{ .start = pos, .end = pos };
        var change = try cha.Change.initInsert(self.allocator, span, &.{'\n'});
        try self.appendChange(&change);
        try self.moveCursor(pos);
        try self.commitChanges();
    }

    pub fn changeAlignIndent(self: *Buffer) !void {
        if (self.selection) |selection| {
            const start: usize = @intCast(selection.start.row);
            const end: usize = @intCast(selection.end.row + 1);
            for (start..end) |row| {
                try self.lineAlignIndent(@intCast(row));
            }
        } else {
            try self.lineAlignIndent(self.cursor.row);
        }
        try self.commitChanges();
    }

    pub fn clearSelection(self: *Buffer) !void {
        if (self.selection == null) return;
        self.selection = null;
        main.editor.dirty.draw = true;
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
        // indicate last line length
        try self.line_positions.append(byte);
    }

    pub fn updateIndents(self: *Buffer) !void {
        const spans = if (self.ts_state) |ts_state| ts_state.indent.spans.items else return;
        self.indents.clearRetainingCapacity();

        var indent_bytes = std.AutoHashMap(usize, void).init(self.allocator);
        defer indent_bytes.deinit();
        var dedent_bytes = std.AutoHashMap(usize, void).init(self.allocator);
        defer dedent_bytes.deinit();
        for (spans) |span| {
            try indent_bytes.put(span.span.start_byte, {});
            try dedent_bytes.put(span.span.end_byte - 1, {});
        }

        var indent: usize = 0;
        var indent_next: usize = 0;
        for (0..self.line_positions.items.len - 1) |row| {
            indent = indent_next;
            const line_byte_start = self.line_positions.items[row];
            const line_byte_end = self.line_positions.items[row + 1];
            var line_indents: usize = 0;
            var line_dedents: usize = 0;
            for (line_byte_start..line_byte_end) |byte| {
                if (indent_bytes.contains(byte)) line_indents += 1;
                if (dedent_bytes.contains(byte)) line_dedents += 1;
            }
            // indent is applied starting from next line, dedent is applied immediately
            switch (std.math.order(line_indents, line_dedents)) {
                .gt => indent_next += 1,
                .lt => {
                    indent = if (indent > 0) indent - 1 else 0;
                    indent_next = if (indent_next > 0) indent_next - 1 else 0;
                },
                else => {},
            }
            try self.indents.append(indent);
        }
    }

    pub fn undo(self: *Buffer) !void {
        log.log(@This(), "undo: {?}/{}\n", .{ self.history_index, self.history.items.len });
        if (self.history_index) |h_idx| {
            const hist_to_undo = self.history.items[h_idx].items;
            var change_iter = std.mem.reverseIterator(hist_to_undo);
            while (change_iter.next()) |change_to_undo| {
                log.log(@This(), "undo change: {}\n", .{change_to_undo});
                var inv_change = try change_to_undo.invert();
                try self.applyChange(&inv_change);
                try self.pending_changes.append(inv_change);
                try self.moveCursor(inv_change.new_span.?.start);
            }
            self.history_index = if (h_idx > 0) h_idx - 1 else null;
        }
    }

    pub fn redo(self: *Buffer) !void {
        log.log(@This(), "redo: {?}/{}\n", .{ self.history_index, self.history.items.len });
        const redo_idx = if (self.history_index) |idx| idx + 1 else 0;
        if (redo_idx >= self.history.items.len) return;
        const redo_hist = self.history.items[redo_idx].items;
        for (redo_hist) |change| {
            var redo_change = try change.clone(self.allocator);
            try self.applyChange(&redo_change);
            try self.pending_changes.append(redo_change);
        }
        self.history_index = redo_idx;
    }

    pub fn textAt(self: *Buffer, allocator: std.mem.Allocator, span: Span) ![]const u21 {
        var res = std.ArrayList(u21).init(allocator);
        for (@intCast(span.start.row)..@intCast(span.end.row + 1)) |row| {
            if (row >= self.content.items.len) break;
            const line = &self.content.items[row];
            if (row == span.start.row and row == span.end.row) {
                try res.appendSlice(line.items[@intCast(span.start.col)..@intCast(span.end.col)]);
            } else if (row == span.start.row) {
                try res.appendSlice(line.items[@intCast(span.start.col)..]);
                try res.append('\n');
            } else if (row == span.end.row) {
                try res.appendSlice(line.items[0..@intCast(span.end.col)]);
            } else {
                try res.appendSlice(line.items);
                try res.append('\n');
            }
        }
        return res.toOwnedSlice();
    }

    pub fn rawTextAt(self: *Buffer, allocator: std.mem.Allocator, span: Span) ![]const u8 {
        const text = try self.textAt(self.allocator, span);
        defer self.allocator.free(text);
        return try uni.utf8ToBytes(allocator, text);
    }

    pub fn goToDefinition(self: *Buffer) !void {
        for (self.lsp_connections.items) |conn| {
            try conn.goToDefinition();
        }
    }

    pub fn showHover(self: *Buffer) !void {
        log.log(@This(), "show hover\n", .{});
        for (self.lsp_connections.items) |conn| {
            try conn.hover();
        }
    }

    pub fn copySelectionToClipboard(self: *Buffer) !void {
        if (self.selection) |selection| {
            const last_line = self.content.items[@intCast(selection.end.row)].items;
            const text = try self.rawTextAt(self.allocator, selection.toExclusiveEnd(last_line.len));
            defer self.allocator.free(text);
            try clp.write(self.allocator, text);
            try main.editor.enterMode(.normal);
        }
    }

    pub fn changeInsertFromClipboard(self: *Buffer) !void {
        if (main.editor.mode == .select or main.editor.mode == .select_line) {
            return error.Todo;
        }
        const text = try clp.read(self.allocator);
        defer self.allocator.free(text);
        const text_uni = try uni.utf8FromBytes(self.allocator, text);
        defer self.allocator.free(text_uni);
        try self.changeInsertText(text_uni);
        try self.commitChanges();
    }

    pub fn selectChar(self: *Buffer) !void {
        self.selection = .{ .start = self.cursor, .end = self.cursor };
        main.editor.dirty.draw = true;
    }

    pub fn selectLine(self: *Buffer) !void {
        const row = self.cursor.row;
        const line = self.content.items[@intCast(row)].items;
        self.selection = .{
            .start = .{ .row = row, .col = 0 },
            .end = .{ .row = row, .col = @intCast(line.len) },
        };
        main.editor.dirty.draw = true;
    }

    fn applyChange(self: *Buffer, change: *cha.Change) !void {
        const span = change.old_span;

        if (builtin.mode == .Debug) {
            if (change.old_text) |old_text| {
                const text_at = try self.textAt(self.allocator, span);
                defer self.allocator.free(text_at);
                log.assertEql(@This(), u21, old_text, text_at);
            } else {
                std.debug.assert(std.meta.eql(span.start, span.end));
            }
        }

        try self.moveCursor(span.start);
        try self.deleteSpan(span);
        self.cursor = span.start;
        if (change.new_text) |new_text| try self.insertText(new_text);
        change.new_span = .{ .start = span.start, .end = self.cursor };
        log.log(@This(), "applied change: {}\n", .{change});
    }

    fn deleteSpan(self: *Buffer, span: Span) !void {
        if (!std.meta.eql(span.start, span.end)) {
            if (span.end.row - span.start.row > 1) {
                // remove fully selected lines
                try self.deleteLineRange(@intCast(span.start.row + 1), @intCast(span.end.row));
            }
            // start and end on separate lines
            if (span.end.row - span.start.row > 0) {
                try self.deleteToEnd(span.start);
                const new_end: Cursor = .{ .row = span.start.row + 1, .col = span.end.col };
                if (new_end.row < self.content.items.len) {
                    try self.deleteToStart(new_end);
                    try self.joinWithLineBelow(@intCast(span.start.row));
                }
            } else {
                // start and end on the same line
                var line = &self.content.items[@intCast(span.start.row)];
                try line.replaceRange(
                    @intCast(span.start.col),
                    @intCast(span.end.col - span.start.col),
                    &[_]u21{},
                );
            }
        }
        try self.moveCursor(span.start);
    }

    fn joinWithLineBelow(self: *Buffer, row: usize) !void {
        var line = &self.content.items[row];
        var next_line = self.content.orderedRemove(row + 1);
        defer next_line.deinit();
        try line.appendSlice(next_line.items);
    }

    /// Delete every character from cursor (including) to the end of line
    fn deleteToEnd(self: *Buffer, cursor: Cursor) !void {
        var line = &self.content.items[@intCast(cursor.row)];
        try line.replaceRange(
            @intCast(cursor.col),
            line.items.len - @as(usize, @intCast(cursor.col)),
            &[_]u21{},
        );
    }

    /// Delete every character from start of line to cursor (excluding)
    fn deleteToStart(self: *Buffer, cursor: Cursor) !void {
        var line = &self.content.items[@intCast(cursor.row)];
        try line.replaceRange(
            0,
            @intCast(cursor.col),
            &[_]u21{},
        );
    }

    /// End is exclusive
    fn deleteLineRange(self: *Buffer, start: usize, end: usize) !void {
        if (end - start <= 0) return;
        for (start..end) |_| {
            const line = self.content.orderedRemove(start);
            line.deinit();
        }
    }

    fn insertText(self: *Buffer, text: []const u21) !void {
        if (self.cursor.row == self.content.items.len) {
            const new_line = std.ArrayList(u21).init(self.allocator);
            try self.content.append(new_line);
        }
        for (text) |ch| {
            var line = &self.content.items[@intCast(self.cursor.row)];

            if (ch == '\n') {
                try self.insertNewline();
            } else {
                try line.insert(@intCast(self.cursor.col), ch);
                try self.moveCursor(self.cursor.applyOffset(.{ .col = 1 }));
            }
        }
    }

    fn insertNewline(self: *Buffer) !void {
        var line = try self.content.items[@intCast(self.cursor.row)].toOwnedSlice();
        defer self.allocator.free(line);
        try self.content.items[@intCast(self.cursor.row)].appendSlice(line[0..@intCast(self.cursor.col)]);
        var new_line = std.ArrayList(u21).init(self.allocator);
        try new_line.appendSlice(line[@intCast(self.cursor.col)..]);
        try self.content.insert(@intCast(self.cursor.row + 1), new_line);
        try self.moveCursor(.{ .row = self.cursor.row + 1, .col = 0 });
    }

    fn lineAlignIndent(self: *Buffer, row: i32) !void {
        const old_cursor = self.cursor;
        const line = self.content.items[@intCast(row)].items;
        const correct_indent: usize = self.indents.items[@intCast(row)];
        const correct_indent_spaces = correct_indent * self.file_type.indent_spaces;
        const current_indent_spaces: usize = lineIndentSpaces(line);
        if (correct_indent_spaces == current_indent_spaces) return;
        const span = Span{
            .start = .{ .row = row, .col = 0 },
            .end = .{ .row = row, .col = @intCast(current_indent_spaces) },
        };
        const new_text = try self.allocator.alloc(u21, correct_indent_spaces);
        defer self.allocator.free(new_text);
        @memset(new_text, ' ');
        const old_text = try self.textAt(self.allocator, span);
        defer self.allocator.free(old_text);
        var change = try cha.Change.initReplace(self.allocator, span, old_text, new_text);
        try self.appendChange(&change);
        try self.moveCursor(old_cursor);
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

    fn scrollForCursor(self: *Buffer, new_buf_cursor: Cursor) void {
        const term_cursor = new_buf_cursor.applyOffset(self.offset.negate());
        // TODO: scrolling without coupling with term
        const dims = ter.Dimensions{
            .height = main.term.dimensions.height,
            .width = main.term.dimensions.width - ter.number_line_width,
        };
        if (term_cursor.row < 0 and new_buf_cursor.row >= 0) {
            self.offset.row += term_cursor.row;
            main.editor.dirty.draw = true;
        } else if (term_cursor.row >= dims.height and new_buf_cursor.row < self.content.items.len) {
            self.offset.row += 1 + term_cursor.row - @as(i32, @intCast(dims.height));
            main.editor.dirty.draw = true;
        } else if (term_cursor.col < 0 and new_buf_cursor.col >= 0) {
            self.offset.col += term_cursor.col;
            main.editor.dirty.draw = true;
        } else if (term_cursor.col >= dims.width and new_buf_cursor.row >= 0 and new_buf_cursor.row < self.content.items.len) {
            const line = &self.content.items[@intCast(new_buf_cursor.row)];
            const line_len = line.items.len;
            if (new_buf_cursor.col <= line_len) {
                self.offset.col += 1 + term_cursor.col - @as(i32, @intCast(dims.width));
                main.editor.dirty.draw = true;
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

fn nextWordStart(line: []u21, pos: usize) ?usize {
    if (line.len == 0) return null;
    var col = pos;
    while (col < line.len - 1) {
        const ch = line[col];
        col += 1;
        const next = line[col];
        if (boundary(ch, next) != null and !isWhitespace(next)) {
            if (isWhitespace(next)) col += 1;
            return col;
        }
    }
    return null;
}

fn wordEnd(line: []u21, pos: usize) ?usize {
    if (line.len == 0) return null;
    var col = pos;
    while (col < line.len - 1) {
        const ch = line[col];
        col += 1;
        const next = line[col];
        if (boundary(ch, next)) |b| {
            if (b == .wordEnd) return col - 1;
        }
    }
    return null;
}

fn tokenEnd(line: []u21, pos: usize) ?usize {
    if (line.len == 0) return null;
    var col = pos;
    while (col < line.len - 1) {
        const ch = line[col];
        col += 1;
        const next = line[col];
        if (isToken(ch) and !isToken(next)) {
            return col - 1;
        }
    }
    return null;
}

const Boundary = enum {
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

fn isDigit(ch: u21) bool {
    return (ch >= 48 and ch <= 57);
}

/// Token is a string that is usually lexed by a programming language as a single name
fn isToken(ch: u21) bool {
    return isAlphabet(ch) or isDigit(ch) or ch == '_' or ch == '-';
}

fn lineIndentSpaces(line: []const u21) usize {
    var leading_spaces: usize = 0;
    for (line) |ch| {
        if (ch != ' ') break;
        leading_spaces += 1;
    }
    return leading_spaces;
}

var scratch_id: usize = 0;
fn nextScratchId() usize {
    scratch_id += 1;
    return scratch_id;
}
