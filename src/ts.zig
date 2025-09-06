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
            var err: ts.TSQueryError = undefined;
            const query = ts.ts_query_new(language, query_str.ptr, @intCast(query_str.len), null, &err);
            if (err > 0) return error.Query;

            return .{
                .query = query,
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
                    if (tuple) |t| try self.spans.append(self.allocator, t);
                }
            }
        }
    };
}

pub const State = struct {
    parser: ?*ts.TSParser = null,
    tree: ?*ts.TSTree = null,
    highlight: ParseResult(AttrsSpan),
    indent: ParseResult(IndentSpanTuple),
    symbol: ?ParseResult(SpanFlat) = null,
    allocator: Allocator,

    pub fn init(allocator: Allocator, ts_conf: ft.TsConfig) !State {
        const language = try ts_conf.loadLanguage(allocator);
        const highlight_query = try ft.TsConfig.loadQuery(allocator, ts_conf.highlight_query);
        defer allocator.free(highlight_query);
        const indent_query = try ft.TsConfig.loadQuery(allocator, ts_conf.indent_query);
        defer allocator.free(indent_query);
        const symbol_query = if (ts_conf.symbol_query) |sq| try ft.TsConfig.loadQuery(allocator, sq) else null;
        defer if (symbol_query) |sq| allocator.free(sq);

        var self = State{
            .parser = ts.ts_parser_new(),
            .allocator = allocator,
            .highlight = try ParseResult(AttrsSpan).init(allocator, language(), highlight_query),
            .indent = try ParseResult(IndentSpanTuple).init(allocator, language(), indent_query),
        };
        if (symbol_query) |sq| self.symbol = try ParseResult(SpanFlat).init(allocator, language(), sq);
        _ = ts.ts_parser_set_language(self.parser, language());

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
        try self.highlight.makeSpans(self.tree.?);
        try self.indent.makeSpans(self.tree.?);
    }

    pub fn deinit(self: *State) void {
        if (self.parser) |p| ts.ts_parser_delete(p);
        if (self.tree) |t| ts.ts_tree_delete(t);
        self.highlight.deinit();
        self.indent.deinit();
        if (self.symbol) |*s| s.deinit();
    }
};

pub const AttrsSpan = struct {
    span: SpanFlat,
    attrs: []const col.Attr,

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
    .{ "number", col.attributes.literal },
    .{ "boolean", col.attributes.literal },
    .{ "comment", col.attributes.comment },
});

pub const IndentSpanTuple = struct {
    span: SpanFlat,
    name: []const u8,

    pub fn init(span: SpanFlat, capture_name: []const u8) ?IndentSpanTuple {
        if (!std.mem.eql(u8, capture_name, "indent.begin")) return null;
        return .{ .span = span, .name = capture_name };
    }
};
