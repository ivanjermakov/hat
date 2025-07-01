const std = @import("std");
const buf = @import("buffer.zig");
const uni = @import("unicode.zig");
const lsp = @import("lsp.zig");

pub const Change = struct {
    span: buf.Span,
    old_text: ?[]const u21 = null,
    new_text: ?[]const u21 = null,
    cursor: ?buf.Cursor = null,
    allocator: std.mem.Allocator,

    pub fn initInsert(allocator: std.mem.Allocator, span: buf.Span, new_text: []const u21) !Change {
        return .{
            .span = span,
            .new_text = try allocator.dupe(u21, new_text),
            .allocator = allocator,
        };
    }

    pub fn initDelete(allocator: std.mem.Allocator, span: buf.Span, old_text: []const u21) !Change {
        return .{
            .span = span,
            .old_text = try allocator.dupe(u21, old_text),
            .allocator = allocator,
        };
    }

    pub fn initReplace(allocator: std.mem.Allocator, span: buf.Span, old_text: []const u21, new_text: []const u21) !Change {
        return .{
            .span = span,
            .old_text = try allocator.dupe(u21, old_text),
            .new_text = try allocator.dupe(u21, new_text),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Change) void {
        if (self.old_text) |t| self.allocator.free(t);
        if (self.new_text) |t| self.allocator.free(t);
    }

    pub fn format(
        self: *const Change,
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

    pub fn invert(self: *const Change) !Change {
        return .{
            .span = self.span,
            .new_text = if (self.old_text) |t| try self.allocator.dupe(u21, t) else null,
            .old_text = if (self.new_text) |t| try self.allocator.dupe(u21, t) else null,
            .cursor = self.cursor,
            .allocator = self.allocator,
        };
    }

    pub fn toLsp(self: *const Change, allocator: std.mem.Allocator) !lsp.types.TextDocumentContentChangeEvent {
        const text = try uni.utf8ToBytes(allocator, self.new_text orelse &.{});
        return .{
            .literal_0 = .{
                .range = self.span.toLsp(),
                .text = text,
            },
        };
    }
};
