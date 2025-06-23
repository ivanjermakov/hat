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
    capture_name: []const u8,

    pub fn attrs(self: *const SpanCaptureTuple) ?[]const col.Attr {
        return syntax_highlight.get(self.capture_name);
    }
};

pub const ts = ts_c;

pub const syntax_highlight = std.StaticStringMap([]const col.Attr).initComptime(.{
    .{ "keyword", col.attributes.keyword },
    .{ "string", col.attributes.string },
    .{ "number", col.attributes.number },
    .{ "comment", col.attributes.comment },
});
