const std = @import("std");
const dl = std.DynLib;
const main = @import("main.zig");
const ft = @import("file_type.zig");
const ts = @import("ts.zig");
const log = @import("log.zig");

pub const Buffer = struct {
    content: BufferContent,
    content_raw: std.ArrayList(u8),
    spans: std.ArrayList(ts.SpanNodeTypeTuple),
    parser: ?*ts.ts.TSParser,
    tree: ?*ts.ts.TSTree,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, content_raw: []u8) !Buffer {
        var raw = std.ArrayList(u8).init(allocator);
        try raw.appendSlice(content_raw);
        var buffer = Buffer{
            .content = std.ArrayList(Line).init(allocator),
            .content_raw = raw,
            .spans = std.ArrayList(ts.SpanNodeTypeTuple).init(allocator),
            .parser = null,
            .tree = null,
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
};

pub const BufferContent = std.ArrayList(Line);

pub const Line = std.ArrayList(u8);
