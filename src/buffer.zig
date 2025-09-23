const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const cha = @import("change.zig");
const clp = @import("clipboard.zig");
const core = @import("core.zig");
const Span = core.Span;
const Cursor = core.Cursor;
const SpanFlat = core.SpanFlat;
const Dimensions = core.Dimensions;
const FatalError = core.FatalError;
const dt = @import("datetime.zig");
const edi = @import("editor.zig");
const ext = @import("external.zig");
const ft = @import("file_type.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const main = @import("main.zig");
const reg = @import("regex.zig");
const ter = @import("terminal.zig");
const ts = @import("ts.zig");
const dia = @import("ui/diagnostic.zig");
const fzf = @import("ui/fzf.zig");
const uni = @import("unicode.zig");
const ur = @import("uri.zig");

pub const Mode = enum {
    normal,
    select,
    select_line,
    insert,

    pub fn isNormalOrSelect(self: Mode) bool {
        return self == .normal or self.isSelect();
    }

    pub fn isSelect(self: Mode) bool {
        return self == .select or self == .select_line;
    }
};

pub const Buffer = struct {
    path: []const u8,
    uri: []const u8,
    file: ?std.fs.File,
    stat: ?std.fs.File.Stat = null,
    /// Incremented on every content change
    version: usize = 0,
    file_type: ft.FileTypeConfig,
    content: std.array_list.Aligned(u21, null) = .empty,
    content_raw: std.array_list.Aligned(u8, null) = .empty,
    mode: Mode = .normal,
    ts_state: ?ts.State = null,
    selection: ?Span = null,
    diagnostics: std.array_list.Aligned(dia.Diagnostic, null) = .empty,
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
    line_positions: std.array_list.Aligned(usize, null) = .empty,
    /// Array list of byte start position of next line
    /// Length equals number of lines, last item means total buffer byte size
    line_byte_positions: std.array_list.Aligned(usize, null) = .empty,
    /// Indent depth for each line
    indents: std.array_list.Aligned(usize, null) = .empty,
    history: std.array_list.Aligned(std.array_list.Aligned(cha.Change, null), null) = .empty,
    history_index: ?usize = null,
    /// History index of the last file save
    /// Used to decide whether buffer has unsaved changes
    file_history_index: ?usize = null,
    /// Changes needed to be sent to LSP clients
    pending_changes: std.array_list.Aligned(cha.Change, null) = .empty,
    /// Changes yet to become a part of Buffer.history
    uncommitted_changes: std.array_list.Aligned(cha.Change, null) = .empty,
    lsp_connections: std.array_list.Aligned(*lsp.LspConnection, null) = .empty,
    scratch: bool = false,
    allocator: Allocator,

    pub fn init(allocator: Allocator, uri: []const u8) !Buffer {
        const buf_path = try ur.toPath(allocator, uri);
        log.debug(@This(), "file path: {s}\n", .{buf_path});
        errdefer allocator.free(buf_path);
        const file_ext = std.fs.path.extension(buf_path);
        const file_type = ft.file_type.get(file_ext) orelse ft.plain;
        log.debug(@This(), "file type: {s}\n", .{file_type.name});
        const file = try std.fs.cwd().openFile(buf_path, .{});

        var self = Buffer{
            .path = buf_path,
            .file = file,
            .file_type = file_type,
            .uri = uri,
            .allocator = allocator,
        };

        const content_raw = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(content_raw);
        try self.content_raw.appendSlice(allocator, content_raw);

        _ = try self.syncFs();
        try self.updateContent();
        try self.updateLinePositions();
        if (self.file_type.ts) |ts_conf| {
            self.ts_state = ts.State.init(allocator, ts_conf) catch |e| b: {
                log.err(@This(), "failed to init TsState: {}\n", .{e});
                if (@errorReturnTrace()) |trace| log.errPrint("{f}\n", .{trace.*});
                break :b null;
            };
        }
        try self.reparse();
        return self;
    }

    pub fn initScratch(allocator: Allocator, content_raw: []const u8) !Buffer {
        const path = try std.fmt.allocPrint(allocator, "scratch{d:0>2}", .{nextScratchId()});

        var self = Buffer{
            .path = path,
            .file = null,
            .file_type = ft.plain,
            .uri = try std.fmt.allocPrint(allocator, "scratch://{s}", .{path}),
            .scratch = true,
            .allocator = allocator,
        };
        try self.content_raw.appendSlice(allocator, content_raw);

        try self.updateContent();
        try self.updateLinePositions();
        if (self.file_type.ts) |ts_conf| {
            self.ts_state = ts.State.init(allocator, ts_conf) catch |e| b: {
                log.err(@This(), "failed to init TsState: {}\n", .{e});
                if (@errorReturnTrace()) |trace| log.errPrint("{f}\n", .{trace.*});
                break :b null;
            };
        }
        try self.reparse();
        return self;
    }

    pub fn reparse(self: *Buffer) FatalError!void {
        self.updateRaw() catch |e| {
            log.err(@This(), "{}\n", .{e});
            if (@errorReturnTrace()) |trace| log.errPrint("{f}\n", .{trace.*});
        };
        if (self.ts_state) |*ts_state| try ts_state.reparse(self.content_raw.items);
        try self.updateLinePositions();
    }

    pub fn updateContent(self: *Buffer) FatalError!void {
        self.content.clearRetainingCapacity();
        try uni.unicodeFromBytesArrayList(self.allocator, &self.content, self.content_raw.items);
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lsp_connections.items) |conn| {
            conn.didClose(self) catch {};
        }
        self.lsp_connections.deinit(self.allocator);

        self.allocator.free(self.uri);
        self.allocator.free(self.path);

        if (self.ts_state) |*ts_state| ts_state.deinit();

        self.content.deinit(self.allocator);
        self.content_raw.deinit(self.allocator);

        self.clearDiagnostics();
        self.diagnostics.deinit(self.allocator);

        self.line_positions.deinit(self.allocator);
        self.line_byte_positions.deinit(self.allocator);
        self.indents.deinit(self.allocator);

        for (self.history.items) |*i| {
            for (i.items) |*c| c.deinit();
            i.deinit(self.allocator);
        }
        self.history.deinit(self.allocator);

        for (self.pending_changes.items) |*c| c.deinit();
        self.pending_changes.deinit(self.allocator);
        for (self.uncommitted_changes.items) |*c| c.deinit();
        self.uncommitted_changes.deinit(self.allocator);

        if (self.file) |f| f.close();
    }

    pub fn enterMode(self: *Buffer, mode: Mode) FatalError!void {
        main.editor.resetHover();

        if (self.mode == mode) return;
        if (self.mode == .insert) try self.commitChanges();

        switch (mode) {
            .normal => {
                self.clearSelection();
                main.editor.completion_menu.reset();
            },
            .select => {
                const end_pos = self.cursorToPos(self.cursor) + 1;
                self.selection = .{ .start = self.cursor, .end = self.posToCursor(end_pos) };
                log.warn(@This(), "selection: {?}\n", .{self.selection});
                main.editor.dirty.draw = true;
            },
            .select_line => {
                self.selection = self.lineSpan(@intCast(self.cursor.row));
                main.editor.dirty.draw = true;
            },
            .insert => self.clearSelection(),
        }
        if (mode != .normal) main.editor.dotRepeatInside();
        log.debug(@This(), "mode: {}->{}\n", .{ self.mode, mode });
        self.mode = mode;
        main.editor.dirty.cursor = true;
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

    pub fn moveCursor(self: *Buffer, new_cursor: Cursor) void {
        const old_cursor = self.cursor;
        const vertical_only = old_cursor.col == new_cursor.col and old_cursor.row != new_cursor.row;

        if (new_cursor.row < 0) {
            self.moveCursor(.{ .row = 0, .col = new_cursor.col });
            return;
        }
        if (new_cursor.row >= self.line_positions.items.len) {
            self.moveCursor(.{ .row = @intCast(self.line_positions.items.len - 1), .col = new_cursor.col });
            return;
        }
        if (new_cursor.col < 0) {
            self.moveCursor(.{ .row = new_cursor.row, .col = 0 });
            return;
        }

        var max_col = ter.lineColLength(self, self.lineContent(@intCast(new_cursor.row)));
        if (max_col > 0 and !self.lineTerminated(@intCast(new_cursor.row))) max_col -= 1;
        var col: i32 = @intCast(@min(new_cursor.col, max_col));
        if (vertical_only) {
            if (self.cursor_desired_col) |desired| {
                col = @intCast(@min(desired, max_col));
            }
        }
        if (!vertical_only) {
            self.cursor_desired_col = @intCast(col);
        }

        self.cursor = .{
            .row = new_cursor.row,
            .col = col,
        };
        self.scrollForCursor(self.cursor);

        switch (self.mode) {
            .select => {
                const selection = &self.selection.?;
                // temporary make selection span inclusive to simplify cursor search
                selection.end = self.posToCursor(self.cursorToPos(selection.end) - 1);
                defer selection.end = self.posToCursor(self.cursorToPos(selection.end) + 1);
                if (std.meta.eql(selection.start, old_cursor)) {
                    selection.start = self.cursor;
                } else {
                    selection.end = self.cursor;
                }
                // restore ends order
                if (selection.start.order(selection.end) == .gt) {
                    const tmp = selection.start;
                    selection.start = selection.end;
                    selection.end = tmp;
                }
                main.editor.dirty.draw = true;
            },
            .select_line => {
                var selection = &self.selection.?;
                const move_start = old_cursor.row == selection.start.row;
                if (move_start) {
                    selection.start.row = self.cursor.row;
                } else {
                    selection.end.row = self.cursor.row + 1;
                }
                // restore ends order
                if (selection.start.row + 1 > selection.end.row) {
                    const tmp = selection.start.row;
                    // exclusive end becomes inclusive start
                    selection.start.row = selection.end.row - 1;
                    // inclusive start becomes exclusive end
                    selection.end.row = tmp + 1;
                }
                main.editor.dirty.draw = true;
            },
            else => {
                self.clearSelection();
            },
        }

        main.editor.dirty.cursor = true;
        main.editor.resetHover();
    }

    pub fn centerCursor(self: *Buffer) void {
        const old_offset_row = self.offset.row;
        const dims = main.term.dimensions;
        const target_row: i32 = @intCast(@divFloor(dims.height, 2));
        const term_row = self.cursor.applyOffset(self.offset.negate()).row;
        self.offset.row = @max(0, self.offset.row + term_row - target_row);
        if (old_offset_row == self.offset.row) return;
        main.editor.dirty.draw = true;
    }

    /// Move to the next word start on the current line
    pub fn moveToNextWord(self: *Buffer) void {
        const old_cursor = self.cursor;
        const line = self.lineContent(@intCast(self.cursor.row));

        if (nextWordStart(line, @intCast(self.cursor.col))) |col| {
            self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
            if (self.selection == null) {
                self.selection = .{ .start = old_cursor, .end = self.posToCursor(self.cursorToPos(self.cursor) + 1) };
                main.editor.dirty.draw = true;
            }
            main.editor.dotRepeatInside();
        }
    }

    /// Move to the previous word start on the current line
    pub fn moveToPrevWord(self: *Buffer) void {
        const old_cursor = self.cursor;
        const line = self.lineContent(@intCast(self.cursor.row));

        var col: i32 = self.cursor.col;
        if (col == 0) return;
        while (true) {
            if (col == 0) break;
            if (col != self.cursor.col) {
                if (boundary(line[@intCast(col)], line[@intCast(col - 1)])) |b| {
                    if (b == .wordEnd) break;
                }
            }
            col -= 1;
        } else {
            return;
        }
        self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
        if (self.selection == null) {
            self.selection = .{
                .start = self.cursor,
                .end = self.posToCursor(self.cursorToPos(old_cursor) + 1),
            };
            main.editor.dirty.draw = true;
        }
        main.editor.dotRepeatInside();
    }

    /// Move to the next word end on the current line
    pub fn moveToWordEnd(self: *Buffer) void {
        const old_cursor = self.cursor;
        const line = self.lineContent(@intCast(self.cursor.row));

        if (wordEnd(line, @intCast(self.cursor.col + 1))) |col| {
            self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
            if (self.selection == null) {
                self.selection = .{ .start = old_cursor, .end = self.posToCursor(self.cursorToPos(self.cursor) + 1) };
                main.editor.dirty.draw = true;
            }
            main.editor.dotRepeatInside();
        }
    }

    /// Move to the next token end on the current line
    /// @see `tokenEnd()`
    pub fn moveToTokenEnd(self: *Buffer) void {
        const old_cursor = self.cursor;
        const line = self.lineContent(@intCast(self.cursor.row));

        if (tokenEnd(line, @intCast(self.cursor.col + 1))) |col| {
            self.moveCursor(.{ .row = self.cursor.row, .col = @intCast(col) });
            if (self.selection == null) {
                self.selection = .{ .start = old_cursor, .end = self.posToCursor(self.cursorToPos(self.cursor) + 1) };
                main.editor.dirty.draw = true;
            }
            main.editor.dotRepeatInside();
        }
    }

    pub fn appendChange(self: *Buffer, change: *cha.Change) FatalError!void {
        try self.applyChange(change);
        try self.uncommitted_changes.append(self.allocator, change.*);
        try self.pending_changes.append(self.allocator, try change.clone(self.allocator));
        main.editor.dirty.completion = true;
    }

    pub fn commitChanges(self: *Buffer) FatalError!void {
        if (self.uncommitted_changes.items.len == 0) {
            log.debug(@This(), "no changes to commit\n", .{});
            return;
        }
        log.debug(@This(), "commit {} changes\n", .{self.uncommitted_changes.items.len});
        if (self.history_index == null or self.history_index.? + 1 != self.history.items.len) {
            log.debug(@This(), "history overwrite, idx: {?}\n", .{self.history_index});
            const i = if (self.history_index) |i| i + 1 else 0;
            for (self.history.items[i..]) |*chs| {
                for (chs.items) |*ch| ch.deinit();
                chs.deinit(self.allocator);
            }
            try self.history.replaceRange(self.allocator, i, self.history.items.len - i, &.{});
        }
        var new_hist = try std.array_list.Aligned(cha.Change, null).initCapacity(self.allocator, 1);
        try new_hist.appendSlice(self.allocator, self.uncommitted_changes.items);
        self.uncommitted_changes.clearRetainingCapacity();
        try self.history.append(self.allocator, new_hist);
        self.history_index = self.history.items.len - 1;

        main.editor.dotRepeatCommitReady();
    }

    pub fn changeInsertText(self: *Buffer, text: []const u21) FatalError!void {
        var change = try cha.Change.initInsert(self.allocator, self, self.cursor, text);
        try self.appendChange(&change);
    }

    pub fn changeSelectionDelete(self: *Buffer) !void {
        if (self.selection) |selection| {
            var change = try cha.Change.initDelete(self.allocator, self, selection);
            try self.appendChange(&change);
        }
    }

    pub fn changeAlignIndent(self: *Buffer) !void {
        if (self.ts_state == null) return;
        try self.updateIndents();
        if (self.selection) |selection| {
            const start: usize = @intCast(selection.start.row);
            const end: usize = @intCast(if (self.mode == .select_line) selection.end.row else selection.end.row + 1);
            for (start..end) |row| {
                try self.lineAlignIndent(@intCast(row));
            }
        } else {
            try self.lineAlignIndent(@intCast(self.cursor.row));
        }
    }

    pub fn clearSelection(self: *Buffer) void {
        if (self.selection == null) return;
        self.selection = null;
        main.editor.dirty.draw = true;
    }

    pub fn clearDiagnostics(self: *Buffer) void {
        for (self.diagnostics.items) |*d| d.deinit();
        self.diagnostics.clearRetainingCapacity();
    }

    pub fn updateLinePositions(self: *Buffer) !void {
        self.line_positions.clearRetainingCapacity();
        self.line_byte_positions.clearRetainingCapacity();
        var line_iter = std.mem.splitScalar(u21, self.content.items, '\n');
        var byte: usize = 0;
        var char: usize = 0;
        while (line_iter.next()) |line| {
            for (line) |ch| {
                byte += std.unicode.utf8CodepointSequenceLength(ch) catch unreachable;
            }
            char += line.len;
            if (char < self.content.items.len and self.content.items[char] == '\n') {
                byte += 1;
                char += 1;
            }
            try self.line_positions.append(self.allocator, char);
            try self.line_byte_positions.append(self.allocator, byte);
        }
        const ps = self.line_positions.items;
        if (ps.len > 1 and ps[ps.len - 1] == ps[ps.len - 2]) {
            // remove phantom line
            _ = self.line_positions.orderedRemove(ps.len - 1);
            _ = self.line_byte_positions.orderedRemove(self.line_byte_positions.items.len - 1);
        }
        log.trace(@This(), "line positions: {any}\n", .{self.line_positions.items});
        log.trace(@This(), "line byte positions: {any}\n", .{self.line_positions.items});
    }

    pub fn updateIndents(self: *Buffer) FatalError!void {
        const ts_state = if (self.ts_state) |ts_state| ts_state else return;
        const spans = if (ts_state.indent) |i| i.spans.items else return;
        try self.reparse();
        self.indents.clearRetainingCapacity();

        var indent_bytes = std.AutoHashMap(usize, void).init(self.allocator);
        defer indent_bytes.deinit();
        var dedent_bytes = std.AutoHashMap(usize, void).init(self.allocator);
        defer dedent_bytes.deinit();
        for (spans) |span| {
            try indent_bytes.put(span.span.start, {});
            try dedent_bytes.put(span.span.end - 1, {});
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
            try self.indents.append(self.allocator, indent);
        }
    }

    pub fn indentEmptyLine(self: *Buffer) FatalError!void {
        if (self.ts_state == null) return;
        std.debug.assert(self.cursor.col == 0);
        if (self.lineLength(@intCast(self.cursor.row)) != 0) return;
        try self.updateIndents();

        const correct_indent: usize = if (self.cursor.row == 0) 0 else self.indents.items[@intCast(self.cursor.row - 1)];
        const correct_indent_spaces = correct_indent * self.file_type.indent_spaces;
        if (correct_indent_spaces > 0) {
            const indent_text = try self.allocator.alloc(u21, correct_indent_spaces);
            defer self.allocator.free(indent_text);
            @memset(indent_text, ' ');
            var indent_change = try cha.Change.initInsert(self.allocator, self, self.cursor, indent_text);
            try self.appendChange(&indent_change);
        }
    }

    pub fn undo(self: *Buffer) !void {
        log.debug(@This(), "undo: {?}/{}\n", .{ self.history_index, self.history.items.len });
        if (self.history_index) |h_idx| {
            const hist_to_undo = self.history.items[h_idx].items;
            var change_iter = std.mem.reverseIterator(hist_to_undo);
            while (change_iter.next()) |change_to_undo| {
                var inv_change = try change_to_undo.invert();
                try self.applyChange(&inv_change);
                try self.pending_changes.append(self.allocator, inv_change);
                self.moveCursor(inv_change.new_span.?.start);
            }
            self.history_index = if (h_idx > 0) h_idx - 1 else null;
        }
    }

    pub fn redo(self: *Buffer) !void {
        log.debug(@This(), "redo: {?}/{}\n", .{ self.history_index, self.history.items.len });
        const redo_idx = if (self.history_index) |idx| idx + 1 else 0;
        if (redo_idx >= self.history.items.len) return;
        const redo_hist = self.history.items[redo_idx].items;
        for (redo_hist) |change| {
            var redo_change = try change.clone(self.allocator);
            try self.applyChange(&redo_change);
            try self.pending_changes.append(self.allocator, redo_change);
            self.moveCursor(change.new_span.?.start);
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

    pub fn posToCursor(self: *const Buffer, pos: usize) Cursor {
        var i: usize = 0;
        var line_start: usize = 0;
        for (self.line_positions.items) |l_pos| {
            if (l_pos > pos) break;
            if (i > 0 and l_pos == self.line_positions.items[i - 1]) break;
            line_start = l_pos;
            i += 1;
        }
        return Cursor{ .row = @intCast(i), .col = @intCast(pos - line_start) };
    }

    pub fn lineTerminated(self: *const Buffer, row: usize) bool {
        return row + 1 < self.line_positions.items.len or self.content.getLast() == '\n';
    }

    /// Line length at `row` (excl. newline char)
    pub fn lineLength(self: *const Buffer, row: usize) usize {
        if (row == 0) {
            if (self.content.items.len == 0) {
                // empty file
                return 0;
            }
            return self.line_positions.items[row] - 1;
        }
        const len = self.line_positions.items[row] - self.line_positions.items[row - 1];
        if (len == 0 or !self.lineTerminated(row)) {
            // phantom line
            return len;
        }
        return len - 1;
    }

    pub fn lineStart(self: *const Buffer, row: usize) usize {
        if (row == 0) return 0;
        return self.line_positions.items[row - 1];
    }

    pub fn lineSpan(self: *const Buffer, row: usize) Span {
        _ = self;
        return .{
            .start = .{ .row = @intCast(row) },
            .end = .{ .row = @intCast(row + 1) },
        };
    }

    pub fn lineContent(self: *const Buffer, row: usize) []const u21 {
        const start = self.lineStart(row);
        return self.content.items[start .. start + self.lineLength(row)];
    }

    pub fn rawTextAt(self: *const Buffer, span: Span) []const u8 {
        const bs = SpanFlat.fromBufSpan(self, span);
        return self.content_raw.items[bs.start..bs.end];
    }

    pub fn renamePrompt(self: *Buffer) !void {
        const cmd = &main.editor.command_line;
        const line = self.lineContent(@intCast(self.cursor.row));
        const name_span = tokenSpan(line, @intCast(self.cursor.col)) orelse return;
        cmd.activate(.rename);
        try cmd.content.appendSlice(self.allocator, line[name_span.start..name_span.end]);
        cmd.cursor = cmd.content.items.len;
    }

    pub fn pipe(self: *Buffer, command: []const u21) !void {
        const command_b = try uni.unicodeToBytes(self.allocator, command);
        defer self.allocator.free(command_b);
        log.debug(@This(), "pipe command: {s}\n", .{command_b});

        const span = if (self.selection) |selection|
            selection
        else
            self.lineSpan(@intCast(self.cursor.row));

        const in_b = try uni.unicodeToBytes(self.allocator, self.textAt(span));
        defer self.allocator.free(in_b);

        var exit_code: u8 = undefined;
        const out_b = ext.runExternalWait(self.allocator, &.{ "sh", "-c", command_b }, in_b, &exit_code) catch |e| {
            log.err(@This(), "{}\n", .{e});
            if (@errorReturnTrace()) |trace| log.errPrint("{f}\n", .{trace.*});
            return;
        };
        defer self.allocator.free(out_b);
        if (exit_code != 0) {
            try main.editor.sendMessage("external command failed");
            return;
        }
        log.debug(@This(), "pipe output: {s}\n", .{out_b});

        if (std.mem.eql(u8, in_b, out_b)) {
            log.debug(@This(), "input unchanged\n", .{});
            return;
        }

        const out = try uni.unicodeFromBytes(self.allocator, out_b);
        defer self.allocator.free(out);
        var change = try cha.Change.initReplace(self.allocator, self, span, out);
        try self.appendChange(&change);
        try self.commitChanges();
    }

    pub fn copySelectionToClipboard(self: *Buffer) !void {
        if (self.selection) |selection| {
            try clp.write(self.allocator, self.rawTextAt(selection));
            try self.enterMode(.normal);
        }
    }

    pub fn changeInsertFromClipboard(self: *Buffer) !void {
        if (self.mode.isSelect()) try self.changeSelectionDelete();
        const text = try clp.read(self.allocator);
        defer self.allocator.free(text);
        const text_uni = try uni.unicodeFromBytes(self.allocator, text);
        defer self.allocator.free(text_uni);
        try self.changeInsertText(text_uni);
        try self.commitChanges();
    }

    pub fn syncFs(self: *Buffer) !bool {
        if (self.scratch) return false;
        const stat = try std.fs.cwd().statFile(self.path);
        const newer = stat.mtime > if (self.stat) |s| s.mtime else 0;
        if (newer) {
            if (log.enabled(.debug)) {
                const time = dt.Datetime.fromSeconds(@as(f64, @floatFromInt(stat.mtime)) / std.time.ns_per_s);
                var time_buf: [32]u8 = undefined;
                const time_str = time.formatISO8601Buf(&time_buf, false) catch "";
                log.debug(@This(), "mtime {} ({s})\n", .{ stat.mtime, time_str });
            }
            self.stat = stat;
        }
        return newer;
    }

    pub fn changeFsExternal(self: *Buffer) !void {
        const old_cursor = self.cursor;
        const file = try std.fs.cwd().openFile(self.path, .{});
        defer file.close();
        const file_content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_content);
        const file_content_uni = try uni.unicodeFromBytes(self.allocator, file_content);
        defer self.allocator.free(file_content_uni);

        var change = try cha.Change.initReplace(self.allocator, self, self.fullSpan(), file_content_uni);
        try self.appendChange(&change);
        try self.commitChanges();
        self.file_history_index = self.history_index;

        // TODO: attempt to keep cursor at the same semantic place
        self.moveCursor(old_cursor);
    }

    pub fn findNext(self: *Buffer, query: []const u21, forward: bool) FatalError!void {
        const query_b = uni.unicodeToBytes(self.allocator, query) catch unreachable;
        log.debug(@This(), "find query: {s}\n", .{query_b});
        defer self.allocator.free(query_b);
        const spans = self.find(query_b) catch {
            try main.editor.sendMessageFmt("invalid search: {s}", .{query_b});
            return;
        };
        defer self.allocator.free(spans);
        const cursor_pos = self.cursorToPos(self.cursor);
        var match: ?usize = null;
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
        if (match) |m| {
            const span = spans[m];
            try main.editor.sendMessageFmt("[{}/{}] {s}", .{ m + 1, spans.len, query_b });
            self.moveCursor(self.posToCursor(span.start));
            self.selection = .fromSpanFlat(self, span);
        }
    }

    pub fn findNextDiagnostic(self: *Buffer, forward: bool) !void {
        const diagnostic: dia.Diagnostic = b: for (self.diagnostics.items, 0..) |_, i_| {
            const i = if (forward) i_ else self.diagnostics.items.len - i_ - 1;
            const diagnostic = self.diagnostics.items[i];
            const ord = self.cursor.order(diagnostic.span.start);
            if (forward) {
                if (ord == .lt) break :b diagnostic;
            } else {
                if (ord == .gt) break :b diagnostic;
            }
        } else {
            if (self.diagnostics.items.len > 0) {
                break :b self.diagnostics.items[if (forward) 0 else self.diagnostics.items.len - 1];
            } else {
                try main.editor.sendMessage("no diagnostics");
                return;
            }
        };

        self.moveCursor(diagnostic.span.start);
        self.centerCursor();
        main.editor.resetHover();
        main.editor.hover_contents = try main.editor.allocator.dupe(u8, diagnostic.message);
        main.editor.dirty.draw = true;
    }

    pub fn applyTextEdits(self: *Buffer, text_edits: []const lsp.types.TextEdit) !void {
        // should be applied in reverse order to preserve original positions
        for (0..text_edits.len) |i_| {
            const i = text_edits.len - i_ - 1;
            const edit = text_edits[i];
            var change = try cha.Change.fromLsp(self.allocator, self, edit);
            log.debug(@This(), "change: {s}: {f}\n", .{ self.path, change });
            try self.appendChange(&change);
        }
    }

    fn find(self: *Buffer, query: []const u8) ![]const SpanFlat {
        var spans: std.array_list.Aligned(SpanFlat, null) = .empty;
        var re = try reg.Regex.from(query, false, self.allocator);
        defer re.deinit();

        var matches = re.searchAll(self.content_raw.items, 0, -1);
        defer re.deinitMatchList(&matches);
        for (0..matches.items.len) |i| {
            const match = matches.items[i];
            try spans.append(self.allocator, SpanFlat.fromRegex(match));
        }
        return spans.toOwnedSlice(self.allocator);
    }

    fn fullSpan(self: *Buffer) Span {
        return .fromSpanFlat(self, .{ .start = 0, .end = self.content.items.len });
    }

    fn applyChange(self: *Buffer, change: *cha.Change) FatalError!void {
        log.trace(@This(), "apply {f}\n", .{change});
        const span = change.old_span;

        if (builtin.mode == .Debug) {
            log.assertEql(@This(), u21, change.old_text, self.textAt(span));
        }

        self.moveCursor(span.start);
        const delete_start = self.cursorToPos(span.start);
        const delete_end = self.cursorToPos(span.end);
        try self.content.replaceRange(self.allocator, delete_start, delete_end - delete_start, change.new_text orelse &.{});
        try self.updateLinePositions();
        change.new_span = .{
            .start = span.start,
            .end = self.posToCursor(delete_start + if (change.new_text) |new_text| new_text.len else 0),
        };
        change.new_span_flat = SpanFlat.fromBufSpan(self, change.new_span.?);
        self.moveCursor(change.new_span.?.end);

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

    fn lineAlignIndent(self: *Buffer, row: usize) !void {
        const old_cursor = self.cursor;
        const line = self.lineContent(row);
        const correct_indent: usize = if (row == 0) 0 else self.indents.items[row - 1];
        const correct_indent_spaces = correct_indent * self.file_type.indent_spaces;
        const current_indent_spaces: usize = lineIndentSpaces(line);
        if (correct_indent_spaces == current_indent_spaces) return;
        const span = Span{
            .start = .{ .row = @intCast(row), .col = 0 },
            .end = .{ .row = @intCast(row), .col = @intCast(current_indent_spaces) },
        };
        const new_text = try self.allocator.alloc(u21, correct_indent_spaces);
        defer self.allocator.free(new_text);
        @memset(new_text, ' ');
        var change = try cha.Change.initReplace(self.allocator, self, span, new_text);
        try self.appendChange(&change);
        self.moveCursor(old_cursor);
    }

    fn updateRaw(self: *Buffer) !void {
        var writer = std.io.Writer.Allocating.init(self.allocator);
        defer writer.deinit();
        try uni.unicodeToBytesWrite(&writer.writer, self.content.items);
        self.content_raw.clearRetainingCapacity();
        try self.content_raw.appendSlice(self.allocator, writer.written());
    }

    fn scrollForCursor(self: *Buffer, new_buf_cursor: Cursor) void {
        const area_cursor = (Cursor{ .row = new_buf_cursor.row, .col = @intCast(ter.cursorTermCol(self, new_buf_cursor)) })
            .applyOffset(self.offset.negate());
        const dims = ter.computeLayout(main.term.dimensions).buffer.dims;
        if (area_cursor.row < 0) {
            self.offset.row += area_cursor.row;
            main.editor.dirty.draw = true;
        }
        if (area_cursor.row >= dims.height and new_buf_cursor.row < self.line_positions.items.len) {
            self.offset.row += 1 + area_cursor.row - @as(i32, @intCast(dims.height));
            main.editor.dirty.draw = true;
        }
        if (area_cursor.col < 0) {
            self.offset.col += area_cursor.col;
            main.editor.dirty.draw = true;
        }
        if (area_cursor.col >= dims.width and new_buf_cursor.row < self.line_positions.items.len) {
            if (new_buf_cursor.col <= self.lineLength(@intCast(new_buf_cursor.row))) {
                self.offset.col += 1 + area_cursor.col - @as(i32, @intCast(dims.width));
                main.editor.dirty.draw = true;
            }
        }
    }
};

pub fn lineIndentSpaces(line: []const u21) usize {
    var leading_spaces: usize = 0;
    for (line) |ch| {
        if (!isWhitespace(ch)) break;
        leading_spaces += 1;
    }
    return leading_spaces;
}

/// Find token span that contains `pos`
pub fn tokenSpan(line: []const u21, pos: usize) ?SpanFlat {
    if (!isToken(line[pos])) return null;
    var col = pos;
    var span: SpanFlat = .{ .start = col, .end = col + 1 };
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
    if (line.len == 0 or pos == line.len - 1) return null;
    var col = pos;
    while (col < line.len - 1) {
        const ch = line[col];
        col += 1;
        const next = line[col];
        if (boundary(ch, next)) |b| {
            if (b == .wordEnd) return col - 1;
        }
    }
    return line.len - 1;
}

fn tokenEnd(line: []const u21, pos: usize) ?usize {
    if (line.len == 0 or pos == line.len - 1) return null;
    var col = pos;
    while (col < line.len - 1) {
        const ch = line[col];
        col += 1;
        const next = line[col];
        if (isToken(ch) and !isToken(next)) {
            return col - 1;
        }
    }
    return line.len - 1;
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
    return ch == ' ';
}

fn isDigit(ch: u21) bool {
    return (ch >= 48 and ch <= 57);
}

/// Token is a string that is usually lexed by a programming language as a single name
fn isToken(ch: u21) bool {
    return isAlphabet(ch) or isDigit(ch) or ch == '_' or ch == '-';
}

var scratch_id: usize = 0;
fn nextScratchId() usize {
    scratch_id += 1;
    return scratch_id;
}

fn testSetupScratch(content: []const u8) !*Buffer {
    try main.testSetup();
    try main.editor.openScratch(content);
    const buffer = main.editor.active_buffer;
    log.debug(@This(), "created test buffer with content: \n{s}", .{buffer.content_raw.items});
    return buffer;
}

fn testSetupTmp(content: []const u8) !*Buffer {
    try main.testSetup();
    const allocator = std.testing.allocator;

    const tmp_file_path = "/tmp/hat_write.txt";
    {
        const tmp_file = try std.fs.cwd().createFile(tmp_file_path, .{ .truncate = true });
        defer tmp_file.close();
        try tmp_file.writeAll(content);
    }

    try main.editor.openBuffer(try ur.fromRelativePath(allocator, tmp_file_path));
    const buffer = main.editor.active_buffer;

    try testing.expectEqualStrings("abc", buffer.content_raw.items);

    log.debug(@This(), "opened tmp file buffer with content: \n{s}", .{buffer.content_raw.items});
    return buffer;
}

test "test buffer" {
    const buffer = try testSetupScratch(
        \\abc
        \\
    );
    defer main.editor.deinit();

    try testing.expectEqualStrings("abc\n", buffer.content_raw.items);
}

test "cursorToPos" {
    var buffer = try testSetupScratch("one");
    defer main.editor.deinit();

    try testing.expectEqualDeep(3, buffer.cursorToPos(.{ .col = 3 }));
}

test "cursorToPos newline" {
    var buffer = try testSetupScratch("one\n");
    defer main.editor.deinit();

    try testing.expectEqualDeep(4, buffer.cursorToPos(.{ .row = 1 }));
}

test "textAt" {
    var buffer = try testSetupScratch("one");
    defer main.editor.deinit();

    try testing.expectEqualSlices(
        u21,
        &.{ 'o', 'n', 'e' },
        buffer.textAt(.{ .start = .{}, .end = .{ .col = 3 } }),
    );
}

test "moveCursor" {
    var buffer = try testSetupScratch(
        \\abc
        \\def
        \\ghijk
    );
    defer main.editor.deinit();

    buffer.moveCursor(.{ .col = 1 });
    try testing.expectEqual(Cursor{ .col = 1 }, buffer.cursor);

    buffer.moveCursor(Cursor{ .row = 2, .col = 2 });
    try testing.expectEqual(Cursor{ .row = 2, .col = 2 }, buffer.cursor);
}

test "moveToNextWord" {
    var buffer = try testSetupScratch("one two three\n");
    defer main.editor.deinit();

    buffer.moveToNextWord();
    try testing.expectEqual(Span{ .start = .{}, .end = .{ .col = 5 } }, buffer.selection);
}

test "moveToPrevWord" {
    var buffer = try testSetupScratch("one two three\n");
    defer main.editor.deinit();

    buffer.moveCursor(.{ .row = 0, .col = 10 });

    buffer.moveToPrevWord();
    try testing.expectEqual(Cursor{ .row = 0, .col = 8 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 8 }, .end = .{ .col = 11 } }, buffer.selection);

    buffer.moveToPrevWord();
    try testing.expectEqual(Cursor{ .row = 0, .col = 4 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 4 }, .end = .{ .col = 9 } }, buffer.selection);
}

test "moveToWordEnd" {
    var buffer = try testSetupScratch("one two three\n");
    defer main.editor.deinit();

    buffer.moveToWordEnd();
    try testing.expectEqual(Cursor{ .row = 0, .col = 2 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 0 }, .end = .{ .col = 3 } }, buffer.selection);

    buffer.moveToWordEnd();
    try testing.expectEqual(Cursor{ .row = 0, .col = 6 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 2 }, .end = .{ .col = 7 } }, buffer.selection);

    buffer.moveToWordEnd();
    try testing.expectEqual(Cursor{ .row = 0, .col = 12 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 6 }, .end = .{ .col = 13 } }, buffer.selection);
}

test "moveToTokenEnd" {
    var buffer = try testSetupScratch("one two three\n");
    defer main.editor.deinit();

    buffer.moveToTokenEnd();
    try testing.expectEqual(Cursor{ .row = 0, .col = 2 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 0 }, .end = .{ .col = 3 } }, buffer.selection);

    buffer.moveToTokenEnd();
    try testing.expectEqual(Cursor{ .row = 0, .col = 6 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 2 }, .end = .{ .col = 7 } }, buffer.selection);

    buffer.moveToTokenEnd();
    try testing.expectEqual(Cursor{ .row = 0, .col = 12 }, buffer.cursor);
    try testing.expectEqualDeep(Span{ .start = .{ .col = 6 }, .end = .{ .col = 13 } }, buffer.selection);
}

test "changeSelectionDelete same line" {
    var buffer = try testSetupScratch("abc\n");
    defer main.editor.deinit();

    buffer.cursor = .{ .row = 0, .col = 1 };
    try buffer.enterMode(.select);
    try buffer.changeSelectionDelete();

    try buffer.commitChanges();
    try buffer.updateRaw();
    try testing.expectEqualStrings("ac\n", buffer.content_raw.items);
}

test "delete selection line to end" {
    var buffer = try testSetupScratch(
        \\abc
        \\def
    );
    defer main.editor.deinit();

    buffer.moveCursor(.{ .row = 0, .col = 1 });
    try buffer.enterMode(.select);
    buffer.moveCursor(.{ .row = 0, .col = 3 });
    try buffer.changeSelectionDelete();

    try buffer.commitChanges();
    try buffer.updateRaw();
    try testing.expectEqualStrings("adef", buffer.content_raw.items);
}

test "delete selection multiple lines" {
    var buffer = try testSetupScratch(
        \\abc
        \\def
        \\ghijk
    );
    defer main.editor.deinit();

    buffer.moveCursor(.{ .row = 0, .col = 1 });
    try buffer.enterMode(.select_line);
    buffer.moveCursor(Cursor{ .row = 1, .col = 2 });

    try testing.expectEqualDeep(
        Span{ .start = .{ .row = 0, .col = 0 }, .end = .{ .row = 2, .col = 0 } },
        buffer.selection.?,
    );
    try buffer.changeSelectionDelete();

    try buffer.commitChanges();
    try buffer.updateRaw();
    try testing.expectEqualStrings("ghijk", buffer.content_raw.items);
}

test "line delete selection" {
    var buffer = try testSetupScratch(
        \\abc
        \\def
        \\ghijk
    );
    defer main.editor.deinit();

    buffer.moveCursor(.{ .row = 0, .col = 1 });
    try buffer.enterMode(.select);
    buffer.moveCursor(Cursor{ .row = 2, .col = 2 });

    try testing.expectEqual(Cursor{ .row = 0, .col = 1 }, buffer.selection.?.start);
    try testing.expectEqual(Cursor{ .row = 2, .col = 3 }, buffer.selection.?.end);
    try buffer.changeSelectionDelete();

    try buffer.commitChanges();
    try buffer.updateRaw();
    try testing.expectEqualStrings("ajk", buffer.content_raw.items);
}

test "textAt full line" {
    var buffer = try testSetupScratch(
        \\abc
        \\def
    );
    defer main.editor.deinit();

    const span = buffer.lineSpan(0);
    try testing.expectEqualSlices(u21, buffer.textAt(span), &.{ 'a', 'b', 'c', '\n' });
}

test "write" {
    const buffer = try testSetupTmp("abc");
    defer main.editor.deinit();

    try buffer.changeInsertText(&.{ 'd', 'e', 'f' });
    try buffer.updateRaw();

    try testing.expectEqualStrings("defabc", buffer.content_raw.items);

    try buffer.write();

    const written = try std.fs.cwd().readFileAlloc(buffer.allocator, buffer.path, std.math.maxInt(usize));
    defer buffer.allocator.free(written);
    try testing.expectEqualStrings("defabc", written);
}

test "undo/redo" {
    var buffer = try testSetupScratch("abc");
    defer main.editor.deinit();

    try buffer.changeInsertText(&.{ 'd', 'e', 'f' });
    try buffer.commitChanges();

    try buffer.updateRaw();
    try testing.expectEqualStrings("defabc", buffer.content_raw.items);

    try buffer.undo();

    try buffer.updateRaw();
    try testing.expectEqualStrings("abc", buffer.content_raw.items);

    try buffer.redo();

    try buffer.updateRaw();
    try testing.expectEqualStrings("defabc", buffer.content_raw.items);
}

test "find" {
    var buffer = try testSetupScratch(
        \\abc
        \\def
        \\bca
    );
    defer main.editor.deinit();

    const query = &.{ 'b', 'c' };

    for (0..2) |_| {
        try buffer.findNext(query, true);
        try testing.expectEqualDeep(
            Span{ .start = .{ .col = 1 }, .end = .{ .col = 3 } },
            buffer.selection,
        );

        try buffer.findNext(query, true);
        try testing.expectEqualDeep(
            Span{ .start = .{ .row = 2, .col = 0 }, .end = .{ .row = 2, .col = 2 } },
            buffer.selection,
        );
    }

    for (0..2) |_| {
        try buffer.findNext(query, false);
        try testing.expectEqualDeep(
            Span{ .start = .{ .col = 1 }, .end = .{ .col = 3 } },
            buffer.selection,
        );

        try buffer.findNext(query, false);
        try testing.expectEqualDeep(
            Span{ .start = .{ .row = 2, .col = 0 }, .end = .{ .row = 2, .col = 2 } },
            buffer.selection,
        );
    }
}
