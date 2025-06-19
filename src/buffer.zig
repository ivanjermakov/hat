const std = @import("std");
const dl = std.DynLib;
const main = @import("main.zig");
const ft = @import("file_type.zig");
const ts = @import("ts.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");

pub const Position = struct {
    line: usize,
    character: usize,

    pub fn order(self: Position, other: Position) std.math.Order {
        if (std.meta.eql(self, other)) return .eq;
        if (self.line == other.line) {
            return std.math.order(self.character, other.character);
        }
        return std.math.order(self.line, other.line);
    }
};

pub const SelectionSpan = struct {
    start: Position,
    end: Position,

    pub fn in_range(self: SelectionSpan, pos: Position) bool {
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, content_raw: []u8) !Buffer {
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
            .allocator = allocator,
        };
        try buffer.init_parser();
        try buffer.update_content();
        return buffer;
    }

    fn init_parser(self: *Buffer) !void {
        const file_ext = std.fs.path.extension(main.args.path.?);
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
        self.allocator.free(self.uri);
    }

    pub fn position(self: *Buffer) Position {
        _ = self;
        return .{
            .line = @intCast(main.cursor.row),
            .character = @intCast(main.cursor.col),
        };
    }

    pub fn inv_position(self: *Buffer, pos: Position) main.Cursor {
        _ = self;
        return .{
            .row = @intCast(pos.line),
            .col = @intCast(pos.character),
        };
    }

    pub fn move_cursor(self: *Buffer, new_cursor: main.Cursor) void {
        const old_position = self.position();
        const valid_cursor = self.validate_cursor(new_cursor) orelse return;

        (&main.cursor).* = valid_cursor;
        if (main.mode == .select) {
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
        main.needs_redraw = true;
    }

    pub fn insert_text(self: *Buffer, text: []u8) !void {
        const view = try std.unicode.Utf8View.init(text);
        var iter = view.iterator();
        while (iter.nextCodepointSlice()) |ch| {
            const cbp = try self.cursor_byte_pos(main.cursor);
            var line = &self.content.items[@intCast(cbp.row)];

            if (std.mem.eql(u8, ch, "\n")) {
                try self.insert_newline();
            } else {
                try line.insertSlice(@intCast(cbp.col), ch);
                main.cursor.col += 1;
            }
        }
        main.needs_reparse = true;
    }

    pub fn insert_newline(self: *Buffer) !void {
        const cbp = try self.cursor_byte_pos(main.cursor);
        const row: usize = @intCast(main.cursor.row);
        var line = try self.content.items[row].toOwnedSlice();
        try self.content.items[row].appendSlice(line[0..@intCast(cbp.col)]);
        var new_line = std.ArrayList(u8).init(main.allocator);
        try new_line.appendSlice(line[@intCast(cbp.col)..]);
        try self.content.insert(@intCast(cbp.row + 1), new_line);
        main.cursor.row += 1;
        main.cursor.col = 0;
        main.needs_reparse = true;
    }

    pub fn remove_char(self: *Buffer) !void {
        const cbp = try self.cursor_byte_pos(main.cursor);
        var line = &self.content.items[@intCast(main.cursor.row)];
        if (main.cursor.col == line.items.len) {
            if (main.cursor.row < self.content.items.len - 1) {
                try self.join_with_line_below(@intCast(main.cursor.row));
            } else {
                return;
            }
        } else {
            _ = line.orderedRemove(@intCast(cbp.col));
            main.needs_reparse = true;
        }
    }

    pub fn remove_prev_char(self: *Buffer) !void {
        const cbp = try self.cursor_byte_pos(main.cursor);
        var line = &self.content.items[@intCast(main.cursor.row)];
        if (cbp.col == 0) {
            if (main.cursor.row > 0) {
                try self.join_with_line_below(@intCast(main.cursor.row - 1));
                main.cursor.row -= 1;
                const joined_line = self.content.items[@intCast(main.cursor.row)];
                main.cursor.col = @intCast(joined_line.items.len);
            } else {
                return;
            }
        } else {
            main.cursor.col -= 1;
            const col_byte = try utf8_byte_pos(line.items, @intCast(main.cursor.col));
            _ = line.orderedRemove(col_byte);
            main.needs_reparse = true;
        }
    }

    pub fn join_with_line_below(self: *Buffer, row: usize) !void {
        var line = &self.content.items[row];
        var next_line = self.content.orderedRemove(row + 1);
        defer next_line.deinit();
        try line.appendSlice(next_line.items);
        main.needs_reparse = true;
    }

    pub fn select_char(self: *Buffer) !void {
        const pos = self.position();
        self.selection = .{ .start = pos, .end = pos };
    }

    fn cursor_byte_pos(self: *Buffer, cursor: main.Cursor) !main.Cursor {
        const row = cursor.row;
        if (row >= self.content.items.len) return error.OutOfBounds;
        const line = &self.content.items[@intCast(cursor.row)];
        const col: i32 = @intCast(try utf8_byte_pos(line.items, @intCast(cursor.col)));
        return .{
            .row = row,
            .col = col,
        };
    }

    fn validate_cursor(self: *Buffer, cursor: main.Cursor) ?main.Cursor {
        const col: i32 = b: {
            const dims = main.term.terminal_size() catch unreachable;
            const in_term = cursor.row >= 0 and cursor.row < dims.height and
                cursor.col >= 0 and cursor.col < dims.width;
            if (!in_term) return null;

            if (cursor.row >= self.content.items.len - 1) return null;
            const line = &self.content.items[@intCast(cursor.row)];
            const max_col = line.items.len;
            const cbp = self.cursor_byte_pos(cursor) catch break :b @intCast(max_col);
            if (cbp.col > max_col) break :b @intCast(max_col);
            break :b cbp.col;
        };

        return .{
            .row = cursor.row,
            .col = col,
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
};

pub const BufferContent = std.ArrayList(Line);

pub const Line = std.ArrayList(u8);
