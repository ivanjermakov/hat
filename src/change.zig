const std = @import("std");
const buf = @import("buffer.zig");
const uni = @import("unicode.zig");

pub const Change = struct {
    span: buf.Span,
    new_text: ?[]const u21,
    old_text: ?[]const u21,
    cursor: ?buf.Cursor = null,

    pub fn format(
        self: Change,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "{},{}-{},{}", .{
            self.span.start.row,
            self.span.start.col,
            self.span.end.row,
            self.span.end.col,
        });
        if (self.new_text) |new_text| {
            _ = try writer.write(" \"");
            for (new_text) |ch| try std.fmt.format(writer, "{u}", .{ch});
            _ = try writer.write("\"");
        }
    }
};
