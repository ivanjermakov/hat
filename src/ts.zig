const std = @import("std");
const col = @import("color.zig");
const ts_c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Span = struct {
    start_byte: usize,
    end_byte: usize,
};

pub const SpanCaptureTuple = struct {
    span: Span,
    /// Dot-separated list of ts node types, forming hierarchy, e.g. identifier.type
    /// @see https://tree-sitter.github.io/tree-sitter/using-parsers/queries/2-operators.html#capturing-nodes
    capture_name: []const u8,

    /// Find attributes corresponding to the capture name
    /// for `identifier.type`, first check for `identifier.type`, then for `identifier`, then return null
    pub fn attrs(self: *const SpanCaptureTuple) ?[]const col.Attr {
        const full = syntax_highlight.get(self.capture_name);
        if (full) |a| return a;
        if (!std.mem.containsAtLeastScalar(u8, self.capture_name, 1, '.')) return null;

        for (0..self.capture_name.len) |i| {
            const from_end = self.capture_name.len - i - 1;
            if (self.capture_name[from_end] == '.') {
                const as = syntax_highlight.get(self.capture_name[0..from_end]);
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
