const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const assert = std.debug.assert;
const reg = @import("regex");
const main = @import("main.zig");
const core = @import("core.zig");
const edi = @import("editor.zig");
const ft = @import("file_type.zig");
const ts = @import("ts.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const cha = @import("change.zig");
const uni = @import("unicode.zig");
const ter = @import("terminal.zig");
const clp = @import("clipboard.zig");
const dt = @import("datetime.zig");

const Span = core.Span;
const Cursor = core.Cursor;
const ByteSpan = core.ByteSpan;
const Dimensions = core.Dimensions;
const Allocator = std.mem.Allocator;

pub const Buffer = struct {
    path: []const u8,
    uri: []const u8,
    file: ?std.fs.File,
    stat: ?std.fs.File.Stat = null,
    /// Incremented on every content change
    version: usize = 0,
    file_type: ft.FileTypeConfig,
    content: std.ArrayList(u21),
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
    /// Array list of character start position of next line
    /// Length equals number of lines, last item means total buffer character size
    line_positions: std.ArrayList(usize),
    /// Array list of byte start position of next line
    /// Length equals number of lines, last item means total buffer byte size
    line_byte_positions: std.ArrayList(usize),
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
    allocator: Allocator,

    pub fn init(allocator: Allocator, path: ?[]const u8, content_raw: []const u8) !Buffer {
        var raw = std.ArrayList(u8).init(allocator);
        try raw.appendSlice(content_raw);
        // make sure last line always ends with newline
        if (raw.getLastOrNull()) |last| {
            if (last != '\n') {
                try raw.append('\n');
            }
        }

        const scratch = path == null;
        const buf_path = if (path) |p|
            try allocator.dupe(u8, p)
        else
            try std.fmt.allocPrint(allocator, "scratch{d:0>2}", .{nextScratchId()});
        const file_ext = std.fs.path.extension(buf_path);
        const file_type = ft.file_type.get(file_ext) orelse ft.plain;
        const file = if (scratch) null else try std.fs.cwd().openFile(buf_path, .{});

        const abs_path = std.fs.realpathAlloc(allocator, buf_path) catch null;
        defer if (abs_path) |a| allocator.free(a);
        const uri = try std.fmt.allocPrint(allocator, "file://{s}", .{abs_path orelse buf_path});
        var self = Buffer{
            .path = buf_path,
            .file = file,
            .file_type = file_type,
            .uri = uri,
            .content = std.ArrayList(u21).init(allocator),
            .content_raw = raw,
            .diagnostics = std.ArrayList(lsp.types.Diagnostic).init(allocator),
            .line_positions = std.ArrayList(usize).init(allocator),
            .line_byte_positions = std.ArrayList(usize).init(allocator),
            .indents = std.ArrayList(usize).init(allocator),
            .history = std.ArrayList(std.ArrayList(cha.Change)).init(allocator),
            .pending_changes = std.ArrayList(cha.Change).init(allocator),
            .uncommitted_changes = std.ArrayList(cha.Change).init(allocator),
            .lsp_connections = std.ArrayList(*lsp.LspConnection).init(allocator),
            .scratch = scratch,
            .allocator = allocator,
        };
        _ = try self.syncFs();
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
    }

    pub fn updateContent(self: *Buffer) !void {
        self.content.clearRetainingCapacity();
        const content_uni = try uni.utf8FromBytes(self.allocator, self.content_raw.items);
        // TODO: less allocations
        defer self.allocator.free(content_uni);
        try self.content.appendSlice(content_uni);
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lsp_connections.items) |conn| {
            conn.didClose(self) catch {};
        }
        self.lsp_connections.deinit();

        self.allocator.free(self.uri);
        self.allocator.free(self.path);

        if (self.ts_state) |*ts_state| ts_state.deinit();

        self.content.deinit();
        self.content_raw.deinit();

        self.diagnostics.deinit();
        self.line_positions.deinit();
        self.line_byte_positions.deinit();
        self.indents.deinit();

        for (self.history.items) |*i| {
            for (i.items) |*c| c.deinit();
            i.deinit();
        }
        self.history.deinit();

        for (self.pending_changes.items) |*c| c.deinit();
        self.pending_changes.deinit();
        self.uncommitted_changes.deinit();

        if (self.file) |f| f.close();
    }

    pub fn write(self: *Buffer) !void {
        try self.updateRaw();

        const file = try std.fs.cwd().createFile(self.path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(self.content_raw.items);
        _ = try self.syncFs();

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

        if (new_cursor.row >= self.line_positions.items.len) return;
        const max_col = self.lineLength(@intCast(new_cursor.row));
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
                } else {
                    selection.start.col = 0;
                    selection.end.row = self.cursor.row;
                }
                selection.end.col = @intCast(self.lineLength(@intCast(selection.end.row)));
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
        defer main.editor.deinit();

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
        const line = self.lineContent(@intCast(self.cursor.row));

        if (nextWordStart(line, @intCast(self.cursor.col))) |col| {
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
        defer main.editor.deinit();

        buffer.cursor = .{ .row = 0, .col = 0 };
        try buffer.moveToNextWord();
        try testing.expectEqual(
            Span{ .start = .{}, .end = .{ .col = 4 } },
            buffer.selection,
        );
    }

    /// TODO: search for next word in preceding lines
    pub fn moveToPrevWord(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const line = self.lineContent(@intCast(self.cursor.row));

        var col: usize = 0;
        while (col < self.cursor.col) {
            if (nextWordStart(line, col)) |word_start| {
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
        const line = self.lineContent(@intCast(self.cursor.row));

        if (wordEnd(line, @intCast(self.cursor.col + 1))) |col| {
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
        const line = self.lineContent(@intCast(self.cursor.row));

        if (tokenEnd(line, @intCast(self.cursor.col + 1))) |col| {
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
        if (self.history_index == null or self.history_index.? + 1 != self.history.items.len) {
            log.log(@This(), "history overwrite, idx: {?}\n", .{self.history_index});
            const i = if (self.history_index) |i| i + 1 else 0;
            for (self.history.items[i..]) |*chs| {
                for (chs.items) |*ch| ch.deinit();
                chs.deinit();
            }
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
        var change = try cha.Change.initInsert(self.allocator, self, self.cursor, text);
        try self.appendChange(&change);
    }

    pub fn changeDeleteChar(self: *Buffer) !void {
        var span: Span = .{ .start = self.cursor, .end = self.cursor.applyOffset(.{ .col = 1 }) };
        const line_len = self.lineLength(@intCast(self.cursor.row));
        if (self.cursor.col == line_len) {
            span.end = .{ .row = self.cursor.row + 1, .col = 0 };
        }
        var change = try cha.Change.initDelete(self.allocator, self, span);
        try self.appendChange(&change);
    }

    pub fn changeDeletePrevChar(self: *Buffer) !void {
        const pos = self.cursorToPos(self.cursor);
        if (pos == 0) return;
        const span: Span = .{ .start = self.posToCursor(pos - 1), .end = self.posToCursor(pos) };
        var change = try cha.Change.initDelete(self.allocator, self, span);
        try self.appendChange(&change);
    }

    pub fn changeJoinWithLineBelow(self: *Buffer, row: usize) !void {
        const span: Span = .{
            .start = .{ .row = @intCast(row), .col = @intCast(self.lineLength(row)) },
            .end = .{ .row = @intCast(row + 1), .col = 0 },
        };
        var change = try cha.Change.initDelete(self.allocator, span, self.textAt(span));
        try self.appendChange(&change);
        try self.commitChanges();
    }

    pub fn changeSelectionDelete(self: *Buffer) !void {
        if (self.selection) |selection| {
            const last_line_len = self.lineLength(@intCast(selection.end.row));
            const span = selection.toExclusiveEnd(last_line_len);
            try main.editor.enterMode(.normal);
            var change = try cha.Change.initDelete(self.allocator, self, span);
            try self.appendChange(&change);
        }
    }

    test "changeSelectionDelete same line" {
        var buffer = try testSetup(
            \\abc
        );
        defer main.editor.deinit();

        buffer.cursor = .{ .row = 0, .col = 1 };
        try main.editor.enterMode(.select);
        try buffer.changeSelectionDelete();

        try buffer.commitChanges();
        try buffer.updateRaw();
        try testing.expectEqualStrings("ac\n", buffer.content_raw.items);
    }

    test "changeSelectionDelete line to end" {
        var buffer = try testSetup(
            \\abc
            \\def
        );
        defer main.editor.deinit();

        try buffer.moveCursor(.{ .row = 0, .col = 1 });
        try main.editor.enterMode(.select);
        try buffer.moveCursor(.{ .row = 0, .col = 3 });
        try buffer.changeSelectionDelete();

        try buffer.commitChanges();
        try buffer.updateRaw();
        try testing.expectEqualStrings("adef\n", buffer.content_raw.items);
    }

    test "changeSelectionDelete multiple lines" {
        var buffer = try testSetup(
            \\abc
            \\def
            \\ghijk
        );
        defer main.editor.deinit();

        try buffer.moveCursor(.{ .row = 0, .col = 1 });
        try main.editor.enterMode(.select);
        try buffer.moveCursor(Cursor{ .row = 2, .col = 2 });

        try testing.expectEqual(Cursor{ .row = 0, .col = 1 }, buffer.selection.?.start);
        try testing.expectEqual(Cursor{ .row = 2, .col = 2 }, buffer.selection.?.end);
        try buffer.changeSelectionDelete();

        try buffer.commitChanges();
        try buffer.updateRaw();
        try testing.expectEqualStrings("ajk\n", buffer.content_raw.items);
    }

    pub fn changeInsertLineBelow(self: *Buffer, row: i32) !void {
        const pos: Cursor = .{ .row = row, .col = @intCast(self.lineLength(@intCast(row))) };
        var change = try cha.Change.initInsert(self.allocator, self, pos, &.{'\n'});
        try self.appendChange(&change);
        try self.commitChanges();
    }

    pub fn changeInsertLineAbove(self: *Buffer, row: i32) !void {
        const pos: Cursor = .{ .row = row, .col = 0 };
        var change = try cha.Change.initInsert(self.allocator, self, pos, &.{'\n'});
        try self.appendChange(&change);
        try self.commitChanges();
        try self.moveCursor(.{ .row = row });
    }

    pub fn changeAlignIndent(self: *Buffer) !void {
        try self.updateIndents();
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
        self.line_byte_positions.clearRetainingCapacity();
        var line_iter = std.mem.splitScalar(u21, self.content.items, '\n');
        var byte: usize = 0;
        var char: usize = 0;
        while (line_iter.next()) |line| {
            for (line) |ch| {
                byte += try std.unicode.utf8CodepointSequenceLength(ch);
            }
            // new line
            byte += 1;
            char += line.len + 1;
            try self.line_positions.append(char);
            try self.line_byte_positions.append(byte);
        }
        // remove phantom line
        const line_count = self.line_positions.items.len;
        if (line_count > 1 and self.line_positions.items[line_count - 1] - self.line_positions.items[line_count - 2] == 1) {
            _ = self.line_positions.orderedRemove(line_count - 1);
            _ = self.line_byte_positions.orderedRemove(line_count - 1);
        }
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
        for (0..self.line_byte_positions.items.len - 1) |row| {
            indent = indent_next;
            const line_byte_start = self.line_byte_positions.items[row];
            const line_byte_end = self.line_byte_positions.items[row + 1];
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
                // log.log(@This(), "undo change: {}\n", .{change_to_undo});
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
            try self.moveCursor(change.new_span.?.start);
        }
        self.history_index = redo_idx;
    }

    pub fn textAt(self: *const Buffer, span: Span) []const u21 {
        return self.content.items[self.cursorToPos(span.start)..self.cursorToPos(span.end)];
    }

    pub fn cursorToPos(self: *const Buffer, cursor: Cursor) usize {
        const line_start = self.lineStart(@intCast(cursor.row));
        return line_start + @as(usize, @intCast(cursor.col));
    }

    pub fn cursorToBytePos(self: *const Buffer, cursor: Cursor) usize {
        const line_start = self.lineStart(@intCast(cursor.row));
        const part_end = line_start + @as(usize, @intCast(cursor.col));
        const part_byte_len = uni.utf8ByteLen(self.content.items[line_start..part_end]) catch unreachable;
        return line_start + part_byte_len;
    }

    pub fn posToCursor(self: *const Buffer, pos: usize) Cursor {
        var i: usize = 0;
        var line_start: usize = 0;
        for (self.line_positions.items) |l_pos| {
            if (l_pos > pos) break;
            line_start = l_pos;
            i += 1;
        }
        return Cursor{ .row = @intCast(i), .col = @intCast(pos - line_start) };
    }

    /// Line character length (excl. newline character)
    pub fn lineLength(self: *const Buffer, row: usize) usize {
        if (row == 0) return self.line_positions.items[row] - 1;
        return self.line_positions.items[row] - self.line_positions.items[row - 1] - 1;
    }

    pub fn lineStart(self: *const Buffer, row: usize) usize {
        if (row == 0) return 0;
        return self.line_positions.items[row - 1];
    }

    pub fn lineContent(self: *const Buffer, row: usize) []const u21 {
        const start = self.lineStart(row);
        return self.content.items[start .. start + self.lineLength(row)];
    }

    pub fn rawTextAt(self: *const Buffer, allocator: Allocator, span: Span) ![]const u8 {
        return try uni.utf8ToBytes(allocator, self.textAt(span));
    }

    pub fn goToDefinition(self: *Buffer) !void {
        for (self.lsp_connections.items) |conn| {
            try conn.goToDefinition();
        }
    }

    pub fn findReferences(self: *Buffer) !void {
        for (self.lsp_connections.items) |conn| {
            try conn.findReferences();
        }
    }

    pub fn showHover(self: *Buffer) !void {
        for (self.lsp_connections.items) |conn| {
            try conn.hover();
        }
    }

    pub fn renamePrompt(self: *Buffer) !void {
        const cmd = &main.editor.command_line;
        const line = self.lineContent(@intCast(self.cursor.row));
        const name_span = tokenSpan(line, @intCast(self.cursor.col)) orelse return;
        try cmd.activate(.rename);
        try cmd.content.appendSlice(line[name_span.start..name_span.end]);
        cmd.cursor = cmd.content.items.len;
    }

    pub fn rename(self: *Buffer, new_text: []const u21) !void {
        for (self.lsp_connections.items) |conn| {
            const new_text_b = try uni.utf8ToBytes(self.allocator, new_text);
            defer self.allocator.free(new_text_b);
            try conn.rename(new_text_b);
        }
    }

    pub fn copySelectionToClipboard(self: *Buffer) !void {
        if (self.selection) |selection| {
            const last_line_len = self.lineLength(@intCast(selection.end.row));
            const text = try self.rawTextAt(self.allocator, selection.toExclusiveEnd(last_line_len));
            defer self.allocator.free(text);
            try clp.write(self.allocator, text);
            try main.editor.enterMode(.normal);
        }
    }

    pub fn changeInsertFromClipboard(self: *Buffer) !void {
        if (main.editor.mode == .select or main.editor.mode == .select_line) {
            try self.changeSelectionDelete();
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
        self.selection = .{
            .start = .{ .row = row, .col = 0 },
            .end = .{ .row = row, .col = @intCast(self.lineLength(@intCast(row))) },
        };
        main.editor.dirty.draw = true;
    }

    pub fn syncFs(self: *Buffer) !bool {
        if (self.scratch) return false;
        const stat = try self.file.?.stat();
        const newer = stat.mtime > if (self.stat) |s| s.mtime else 0;
        if (newer) {
            if (log.enabled) {
                const time = dt.Datetime.fromSeconds(@as(f64, @floatFromInt(stat.mtime)) / std.time.ns_per_s);
                var time_buf: [32]u8 = undefined;
                const time_str = time.formatISO8601Buf(&time_buf, false) catch "";
                log.log(@This(), "mtime {} ({s})\n", .{ stat.mtime, time_str });
            }
            self.stat = stat;
        }
        return newer;
    }

    pub fn changeFsExternal(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const file = try std.fs.cwd().openFile(self.path, .{ .mode = .read_write });
        const file_content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_content);
        const file_content_uni = try uni.utf8FromBytes(self.allocator, file_content);
        defer self.allocator.free(file_content_uni);

        var change = try cha.Change.initReplace(self.allocator, self, self.fullSpan(), file_content_uni);
        try self.appendChange(&change);
        try self.commitChanges();

        // TODO: attempt to keep cursor at the same semantic place
        try self.moveCursor(old_cursor);
    }

    pub fn findNext(self: *Buffer, query: []const u21, forward: bool) !void {
        const query_b = try uni.utf8ToBytes(self.allocator, query);
        defer self.allocator.free(query_b);
        // TODO: catch invalid regex
        const spans = try self.find(query_b);
        defer self.allocator.free(spans);
        const cursor_pos = self.cursorToPos(self.cursor);
        var match: ?usize = null;
        if (forward) {
            for (0..spans.len) |i_| {
                const i = if (forward) i_ else spans.len - i_ - 1;
                if (if (forward) spans[i].start > cursor_pos else spans[i].start < cursor_pos) {
                    match = i;
                    break;
                }
            } else {
                if (spans.len > 0) {
                    match = if (forward) 0 else spans.len - 1;
                } else {
                    try main.editor.sendMessageFmt("no matches for {s}", .{query_b});
                }
            }
        }
        if (match) |m| {
            const span = spans[m];
            try main.editor.sendMessageFmt("[{}/{}] {s}", .{ m + 1, spans.len, query_b });
            try self.moveCursor(self.posToCursor(span.start));
            self.selection = .{
                .start = self.posToCursor(span.start),
                .end = self.posToCursor(span.end - 1),
            };
        }
    }

    fn find(self: *Buffer, query: []const u8) ![]const ByteSpan {
        var spans = std.ArrayList(ByteSpan).init(self.allocator);
        var re = try reg.Regex.from(query, false, self.allocator);
        defer re.deinit();

        var matches = re.searchAll(self.content_raw.items, 0, -1);
        defer re.deinitMatchList(&matches);
        for (0..matches.items.len) |i| {
            const match = matches.items[i];
            try spans.append(ByteSpan.fromRegex(match));
        }
        return spans.toOwnedSlice();
    }

    fn fullSpan(self: *Buffer) Span {
        if (self.content.items.len == 0) return Span{ .start = .{}, .end = .{} };
        return Span{ .start = .{}, .end = .{ .row = @intCast(self.line_positions.items.len) } };
    }

    fn applyChange(self: *Buffer, change: *cha.Change) !void {
        const span = change.old_span;

        if (builtin.mode == .Debug) {
            log.assertEql(@This(), u21, change.old_text, self.textAt(span));
        }

        try self.moveCursor(span.start);
        const delete_start = self.cursorToPos(span.start);
        const delete_end = self.cursorToPos(span.end);
        try self.content.replaceRange(delete_start, delete_end - delete_start, change.new_text orelse &.{});
        try self.updateLinePositions();
        change.new_span = .{
            .start = span.start,
            .end = self.posToCursor(delete_start + if (change.new_text) |new_text| new_text.len else 0),
        };
        change.new_byte_span = ByteSpan.fromBufSpan(self, change.new_span.?);
        try self.moveCursor(change.new_span.?.end);
        self.cursor = change.new_span.?.end;
        std.debug.assert(std.meta.eql(self.cursor, change.new_span.?.end));
        // log.log(@This(), "applied change: {}\n", .{change});

        if (self.ts_state) |*ts_state| try ts_state.edit(change);
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

    fn lineAlignIndent(self: *Buffer, row: i32) !void {
        const old_cursor = self.cursor;
        const line = self.lineContent(@intCast(row));
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
        var change = try cha.Change.initReplace(self.allocator, self, span, new_text);
        try self.appendChange(&change);
        try self.moveCursor(old_cursor);
    }

    fn updateRaw(self: *Buffer) !void {
        self.content_raw.clearRetainingCapacity();
        const raw = try uni.utf8ToBytes(self.allocator, self.content.items);
        // TODO: less allocations
        defer self.allocator.free(raw);
        try self.content_raw.appendSlice(raw);
    }

    fn scrollForCursor(self: *Buffer, new_buf_cursor: Cursor) void {
        const term_cursor = new_buf_cursor.applyOffset(self.offset.negate());
        // TODO: scrolling without coupling with term, store buf dimensions in buffer
        const layout = ter.computeLayout(main.term.dimensions);
        const dims = layout.buffer.dims;
        if (term_cursor.row < 0 and new_buf_cursor.row >= 0) {
            self.offset.row += term_cursor.row;
            main.editor.dirty.draw = true;
        } else if (term_cursor.row >= dims.height and new_buf_cursor.row < self.line_positions.items.len) {
            self.offset.row += 1 + term_cursor.row - @as(i32, @intCast(dims.height));
            main.editor.dirty.draw = true;
        } else if (term_cursor.col < 0 and new_buf_cursor.col >= 0) {
            self.offset.col += term_cursor.col;
            main.editor.dirty.draw = true;
        } else if (term_cursor.col >= dims.width and new_buf_cursor.row >= 0 and new_buf_cursor.row < self.line_positions.items.len) {
            if (new_buf_cursor.col <= self.lineLength(@intCast(new_buf_cursor.row))) {
                self.offset.col += 1 + term_cursor.col - @as(i32, @intCast(dims.width));
                main.editor.dirty.draw = true;
            }
        }
    }

    fn testSetup(content: []const u8) !*Buffer {
        try main.testSetup();
        try main.editor.openScratch(content);
        const buffer = main.editor.active_buffer;
        log.log(@This(), "created test buffer with content: \n{s}", .{buffer.content_raw.items});
        return buffer;
    }

    test "test buffer" {
        const buffer = try testSetup(
            \\abc
        );
        defer main.editor.deinit();

        try testing.expectEqualStrings("abc\n", buffer.content_raw.items);
    }
};

fn nextWordStart(line: []const u21, pos: usize) ?usize {
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

fn wordEnd(line: []const u21, pos: usize) ?usize {
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

fn tokenEnd(line: []const u21, pos: usize) ?usize {
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

/// Find token span that contains `pos`
fn tokenSpan(line: []const u21, pos: usize) ?ByteSpan {
    if (!isToken(line[pos])) return null;
    var col = pos;
    var span: ByteSpan = .{ .start = col, .end = col + 1 };
    while (col < line.len) {
        defer col += 1;
        if (!isToken(line[col])) {
            span.end = col;
            break;
        }
    }
    col = pos;
    while (col > 0) {
        defer col -= 1;
        if (!isToken(line[col])) {
            span.start = col + 1;
            break;
        }
    }
    return span;
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
