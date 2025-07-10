const std = @import("std");
const buf = @import("buffer.zig");
const uni = @import("unicode.zig");
const lsp = @import("lsp.zig");

pub const Change = struct {
    old_span: buf.Span,
    old_text: ?[]const u21 = null,
    new_span: ?buf.Span = null,
    new_text: ?[]const u21 = null,
    allocator: std.mem.Allocator,

    pub fn initInsert(allocator: std.mem.Allocator, span: buf.Span, new_text: []const u21) !Change {
        return .{
            .old_span = span,
            .new_text = try allocator.dupe(u21, new_text),
            .allocator = allocator,
        };
    }

    pub fn initDelete(allocator: std.mem.Allocator, span: buf.Span, old_text: []const u21) !Change {
        return .{
            .old_span = span,
            .old_text = try allocator.dupe(u21, old_text),
            .allocator = allocator,
        };
    }

    pub fn initReplace(allocator: std.mem.Allocator, span: buf.Span, old_text: []const u21, new_text: []const u21) !Change {
        return .{
            .old_span = span,
            .old_text = try allocator.dupe(u21, old_text),
            .new_text = try allocator.dupe(u21, new_text),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Change) void {
        if (self.old_text) |t| self.allocator.free(t);
        if (self.new_text) |t| self.allocator.free(t);
    }

    // pub fn format(
    //     self: *const Change,
    //     comptime fmt: []const u8,
    //     options: std.fmt.FormatOptions,
    //     writer: anytype,
    // ) !void {
    //     _ = fmt;
    //     _ = options;
    //     try std.fmt.format(writer, "{},{}-{},{}", .{
    //         self.old_span.start.row,
    //         self.old_span.start.col,
    //         self.old_span.end.row,
    //         self.old_span.end.col,
    //     });
    //     if (self.new_text) |new_text| {
    //         _ = try writer.write(" \"");
    //         for (new_text) |ch| try std.fmt.format(writer, "{u}", .{ch});
    //         _ = try writer.write("\"");
    //     }
    // }

    pub fn invert(self: *const Change) !Change {
        return .{
            .old_span = self.new_span.?,
            .new_span = self.old_span,
            .new_text = if (self.old_text) |s| try self.allocator.dupe(u21, s) else null,
            .old_text = if (self.new_text) |s| try self.allocator.dupe(u21, s) else null,
            .allocator = self.allocator,
        };
    }

    pub fn clone(self: *const Change, allocator: std.mem.Allocator) !Change {
        var cloned = self.*;
        if (self.new_text) |t| cloned.new_text = try allocator.dupe(u21, t);
        if (self.old_text) |t| cloned.old_text = try allocator.dupe(u21, t);
        return cloned;
    }

    pub fn toLsp(self: *const Change, allocator: std.mem.Allocator) !lsp.types.TextDocumentContentChangeEvent {
        const text = try uni.utf8ToBytes(allocator, self.new_text orelse &.{});
        return .{
            .literal_0 = .{
                .range = self.old_span.toLsp(),
                .text = text,
            },
        };
    }
};
