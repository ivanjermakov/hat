const std = @import("std");
const col = @import("color.zig");
const ft = @import("file_type.zig");
const ts_c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const ts = ts_c;

pub const State = struct {
    spans: std.ArrayList(SpanAttrsTuple),
    parser: ?*ts.TSParser = null,
    query: ?*ts.TSQuery = null,
    tree: ?*ts.TSTree = null,
    allocator: std.mem.Allocator,

    pub fn initParser(self: *State, ts_conf: ft.TsConfig) !void {
        const language = try ts_conf.loadLanguage(self.allocator);
        self.parser = ts.ts_parser_new();
        _ = ts.ts_parser_set_language(self.parser, language());
        const query_str = try ts_conf.loadHighlightQuery(self.allocator);
        defer self.allocator.free(query_str);
        var err: ts.TSQueryError = undefined;
        self.query = ts.ts_query_new(language(), query_str.ptr, @intCast(query_str.len), null, &err);
        if (err > 0) return error.Query;
    }

    pub fn reparse(self: *State, content: []const u8) !void {
        if (self.parser == null) return;

        if (self.tree) |old_tree| ts.ts_tree_delete(old_tree);
        self.tree = ts.ts_parser_parse_string(
            self.parser,
            null,
            @ptrCast(content),
            @intCast(content.len),
        );
        // if (main.log_enabled) {
        //     const node = ts.ts_tree_root_node(self.tree);
        //     log.log(@This(), "tree: {s}\n", .{std.mem.span(ts.ts_node_string(node))});
        // }
        try self.makeSpans();
    }

    pub fn deinit(self: *State) void {
        if (self.parser) |p| ts.ts_parser_delete(p);
        if (self.tree) |t| ts.ts_tree_delete(t);
        if (self.query) |query| ts.ts_query_delete(query);
        self.spans.deinit();
    }

    fn makeSpans(self: *State) !void {
        if (self.tree == null) return;
        self.spans.clearRetainingCapacity();

        const cursor: *ts.TSQueryCursor = ts.ts_query_cursor_new().?;
        defer ts.ts_query_cursor_delete(cursor);
        const root_node = ts.ts_tree_root_node(self.tree);
        ts.ts_query_cursor_exec(cursor, self.query.?, root_node);

        var match: ts.TSQueryMatch = undefined;
        while (ts.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |capture| {
                var capture_name_len: u32 = undefined;
                const capture_name = ts.ts_query_capture_name_for_id(self.query.?, capture.index, &capture_name_len);
                const node_type = capture_name[0..capture_name_len];
                const span: Span = .{
                    .start_byte = ts.ts_node_start_byte(capture.node),
                    .end_byte = ts.ts_node_end_byte(capture.node),
                };
                try self.spans.append(SpanAttrsTuple.init(span, node_type));
            }
        }
    }
};

pub const Span = struct {
    start_byte: usize,
    end_byte: usize,
};

pub const SpanAttrsTuple = struct {
    span: Span,
    attrs: []const col.Attr,

    /// Capture name is a dot-separated list of ts node types, forming hierarchy, e.g. `identifier.type`
    /// @see https://tree-sitter.github.io/tree-sitter/using-parsers/queries/2-operators.html#capturing-nodes
    pub fn init(span: Span, capture_name: []const u8) SpanAttrsTuple {
        return .{
            .span = span,
            .attrs = if (findAttrs(capture_name)) |as| as else col.attributes.text,
        };
    }

    /// Will find attributes corresponding to the capture name:
    /// for `identifier.type`:
    ///   * check `identifier.type`
    ///   * check `identifier`
    ///   * null
    pub fn findAttrs(capture_name: []const u8) ?[]const col.Attr {
        const full = syntax_highlight.get(capture_name);
        if (full) |a| return a;
        if (!std.mem.containsAtLeastScalar(u8, capture_name, 1, '.')) return null;

        for (0..capture_name.len) |i| {
            const from_end = capture_name.len - i - 1;
            if (capture_name[from_end] == '.') {
                const as = syntax_highlight.get(capture_name[0..from_end]);
                if (as) |a| return a;
            }
        }
        return null;
    }
};

pub const syntax_highlight = std.StaticStringMap([]const col.Attr).initComptime(.{
    .{ "keyword", col.attributes.keyword },
    .{ "string", col.attributes.string },
    .{ "number", col.attributes.number },
    .{ "comment", col.attributes.comment },
});
