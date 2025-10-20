const std = @import("std");
const Allocator = std.mem.Allocator;

const buf = @import("buffer.zig");
const cha = @import("change.zig");
const col = @import("color.zig");
const core = @import("core.zig");
const SpanFlat = core.SpanFlat;
const ft = @import("file_type.zig");
const log = @import("log.zig");

const ts_c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const ts = ts_c;

pub fn ParseResult(comptime SpanType: type) type {
    return struct {
        const Self = @This();

        query: ?*ts.TSQuery = null,
        spans: std.array_list.Aligned(SpanType, null) = .empty,
        allocator: Allocator,

        pub fn init(allocator: Allocator, language: *ts.struct_TSLanguage, query_str: []const u8) !ParseResult(SpanType) {
            return .{
                .query = try queryNew(language, query_str),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.query) |query| ts.ts_query_delete(query);
            self.spans.deinit(self.allocator);
        }

        pub fn makeSpans(self: *Self, tree: *ts.TSTree) !void {
            self.spans.clearRetainingCapacity();

            const cursor: *ts.TSQueryCursor = ts.ts_query_cursor_new().?;
            defer ts.ts_query_cursor_delete(cursor);
            const root_node = ts.ts_tree_root_node(tree);
            ts.ts_query_cursor_exec(cursor, self.query.?, root_node);

            var match: ts.TSQueryMatch = undefined;
            while (ts.ts_query_cursor_next_match(cursor, &match)) {
                for (match.captures[0..match.capture_count]) |capture| {
                    var capture_name_len: u32 = undefined;
                    const capture_name = ts.ts_query_capture_name_for_id(self.query.?, capture.index, &capture_name_len);
                    const node_type = capture_name[0..capture_name_len];
                    const span: SpanFlat = .{
                        .start = ts.ts_node_start_byte(capture.node),
                        .end = ts.ts_node_end_byte(capture.node),
                    };
                    const tuple = SpanType.init(span, node_type);
                    log.trace(@This(), "init {s}: {s} -> {?}\n", .{ @typeName(SpanType), capture_name, tuple });
                    if (tuple) |t| try self.spans.append(self.allocator, t);
                }
            }
        }
    };
}

pub const Query = struct {
    query: ?*ts.TSQuery,
    captures: std.AutoHashMap(usize, ts.TSQueryCapture),
    allocator: Allocator,

    pub fn init(allocator: Allocator, language: *ts.struct_TSLanguage, query_str: []const u8) !Query {
        return .{
            .query = try queryNew(language, query_str),
            .captures = std.AutoHashMap(usize, ts.TSQueryCapture).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Query) void {
        self.captures.deinit();
    }

    pub fn capture(self: *Query, tree: *ts.TSTree) !void {
        self.captures.clearRetainingCapacity();

        const cursor: *ts.TSQueryCursor = ts.ts_query_cursor_new().?;
        defer ts.ts_query_cursor_delete(cursor);
        const root_node = ts.ts_tree_root_node(tree);
        ts.ts_query_cursor_exec(cursor, self.query.?, root_node);

        var match: ts.TSQueryMatch = undefined;
        while (ts.ts_query_cursor_next_match(cursor, &match)) {
            for (match.captures[0..match.capture_count]) |cap| {
                try self.captures.put(@intFromPtr(cap.node.id), cap);
            }
        }
    }
};

pub const State = struct {
    parser: ?*ts.TSParser = null,
    tree: ?*ts.TSTree = null,
    highlight: ?ParseResult(AttrsSpan) = null,
    indent: ?Query = null,
    symbol: ?ParseResult(SpanFlat) = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, ts_conf: ft.TsConfig) !State {
        const language = (try ts_conf.loadLanguage(allocator))();

        var self = State{
            .parser = ts.ts_parser_new(),
            .allocator = allocator,
        };

        const highlight_query = if (ts_conf.highlight_query) |q| try ft.TsConfig.loadQuery(allocator, q) else null;
        defer if (highlight_query) |q| allocator.free(q);
        if (highlight_query) |q| self.highlight = try ParseResult(AttrsSpan).init(allocator, language, q);

        const indent_query = if (ts_conf.indent_query) |q| try ft.TsConfig.loadQuery(allocator, q) else null;
        defer if (indent_query) |q| allocator.free(q);
        if (indent_query) |q| self.indent = try .init(allocator, language, q);

        const symbol_query = if (ts_conf.symbol_query) |q| try ft.TsConfig.loadQuery(allocator, q) else null;
        defer if (symbol_query) |q| allocator.free(q);
        if (symbol_query) |q| self.symbol = try ParseResult(SpanFlat).init(allocator, language, q);

        _ = ts.ts_parser_set_language(self.parser, language);

        return self;
    }

    pub fn edit(self: *State, change: *const cha.Change) !void {
        std.debug.assert(self.tree != null);
        const edit_input = change.toTs();
        ts.ts_tree_edit(self.tree, &edit_input);
    }

    pub fn reparse(self: *State, content: []const u8) !void {
        if (self.parser == null) return;

        self.tree = ts.ts_parser_parse_string(
            self.parser,
            self.tree,
            @ptrCast(content),
            @intCast(content.len),
        );
        if (log.enabled(.trace)) {
            const root_node = ts.ts_tree_root_node(self.tree);
            log.trace(@This(), "parse tree:\n{s}\n", .{ts.ts_node_string(root_node)});
        }
        if (self.highlight) |*h| {
            try h.makeSpans(self.tree.?);
            log.trace(@This(), "made {} highlight spans\n", .{h.spans.items.len});
        }
        if (self.indent) |*i| {
            try i.capture(self.tree.?);
            log.trace(@This(), "found {} indent captures\n", .{i.captures.count()});
        }
    }

    pub fn deinit(self: *State) void {
        if (self.parser) |p| ts.ts_parser_delete(p);
        if (self.tree) |t| ts.ts_tree_delete(t);
        if (self.highlight) |*h| h.deinit();
        if (self.indent) |*h| h.deinit();
        if (self.symbol) |*s| s.deinit();
    }
};

pub const AttrsSpan = struct {
    span: SpanFlat,
    attrs: []const col.Attribute,

    /// Capture name is a dot-separated list of ts node types, forming hierarchy, e.g. `identifier.type`
    /// @see https://tree-sitter.github.io/tree-sitter/using-parsers/queries/2-operators.html#capturing-nodes
    pub fn init(span: SpanFlat, capture_name: []const u8) ?AttrsSpan {
        return .{
            .span = span,
            .attrs = if (findAttrs(capture_name)) |as| as else return null,
        };
    }

    /// Will find attributes corresponding to the capture name:
    /// for `identifier.type`:
    ///   * check `identifier.type`
    ///   * check `identifier`
    ///   * null
    pub fn findAttrs(capture_name: []const u8) ?[]const col.Attribute {
        if (node_highlights_exact.get(capture_name)) |a| return a;
        if (node_highlights.get(capture_name)) |a| return a;
        if (!std.mem.containsAtLeastScalar(u8, capture_name, 1, '.')) return null;

        for (0..capture_name.len) |i| {
            const from_end = capture_name.len - i - 1;
            if (capture_name[from_end] == '.') {
                const as = node_highlights.get(capture_name[0..from_end]);
                if (as) |a| return a;
            }
        }
        return null;
    }
};

pub const node_highlights = std.StaticStringMap([]const col.Attribute).initComptime(.{
    .{ "keyword", col.Attribute.keyword },
    .{ "string", col.Attribute.string },
    .{ "number", col.Attribute.literal },
    .{ "boolean", col.Attribute.literal },
    .{ "comment", col.Attribute.comment },
});

pub const node_highlights_exact = std.StaticStringMap([]const col.Attribute).initComptime(.{
    .{ "tag", col.Attribute.keyword },
});

pub fn firstSmallestDescendentInSpan(node: ts.TSNode, span: SpanFlat) ?ts.TSNode {
    const node_start = ts.ts_node_start_byte(node);
    const node_end = ts.ts_node_end_byte(node);

    if (node_end < span.start) return null;
    const child_count = ts.ts_node_child_count(node);
    if (child_count == 0 and node_start >= span.start) return node;

    for (0..child_count) |child_idx| {
        const child_candidate = ts.ts_node_child(node, @intCast(child_idx));
        const child_opt = firstSmallestDescendentInSpan(child_candidate, span);
        if (child_opt) |child| return child;
    }
    return null;
}

fn queryNew(language: *ts.struct_TSLanguage, query_str: []const u8) !?*ts.TSQuery {
    var err: ts.TSQueryError = undefined;
    var err_offset: u32 = undefined;
    const query = ts.ts_query_new(language, query_str.ptr, @intCast(query_str.len), &err_offset, &err);
    if (err > 0) {
        log.err(@This(), "query error position: {}\n", .{err_offset}, null);
        if (log.enabled(.trace)) {
            if (err_offset < query_str.len) {
                log.errPrint("{s}\n^\n", .{query_str[err_offset..@min(err_offset + 10, query_str.len)]});
            } else {
                log.errPrint("error offset outside of query string\n", .{});
            }
        }
        return error.Query;
    }
    return query;
}
