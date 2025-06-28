const std = @import("std");
const buf = @import("buffer.zig");

pub const Change = struct {
    span: buf.Span,
    new_text: []const u21,
    old_text: []const u21,
    cursor: ?buf.Cursor = null,
};
