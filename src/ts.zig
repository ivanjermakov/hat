const std = @import("std");
const col = @import("color.zig");
const ts_c = @cImport({
    @cInclude("tree_sitter/api.h");
});

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
    pub fn findAttrs(capture_name: []const u8) ?[] const col.Attr {
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

pub const ts = ts_c;

pub const syntax_highlight = std.StaticStringMap([]const col.Attr).initComptime(.{
    .{ "keyword", col.attributes.keyword },
    .{ "string", col.attributes.string },
    .{ "number", col.attributes.number },
    .{ "comment", col.attributes.comment },
});
