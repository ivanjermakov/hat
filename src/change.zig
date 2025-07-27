const std = @import("std");
const buf = @import("buffer.zig");
const uni = @import("unicode.zig");
const lsp = @import("lsp.zig");
const ts = @import("ts.zig");

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

    pub fn format(
        self: *const Change,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try std.fmt.format(writer, "change {},{}-{},{}", .{
            self.old_span.start.row,
            self.old_span.start.col,
            self.old_span.end.row,
            self.old_span.end.col,
        });
        if (self.old_text) |old_text| {
            _ = try writer.write(" \"");
            for (old_text) |ch| try std.fmt.format(writer, "{u}", .{ch});
            _ = try writer.write("\"");
        }
        if (self.new_span) |new_span| {
            try std.fmt.format(writer, " -> {},{}-{},{}", .{
                new_span.start.row,
                new_span.start.col,
                new_span.end.row,
                new_span.end.col,
            });
        }
        if (self.new_text) |new_text| {
            _ = try writer.write(" \"");
            for (new_text) |ch| try std.fmt.format(writer, "{u}", .{ch});
            _ = try writer.write("\"");
        }
    }

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

    pub fn toTs(self: *const Change, buffer: *const buf.Buffer) ts.ts.TSInputEdit {
        const start_point = self.old_span.start.toTs();
        const old_end_point = self.old_span.end.toTs();
        const new_end_point = if (self.new_span) |new_span| new_span.end.toTs() else old_end_point;
        const start_byte: u32 = @intCast(buffer.cursorToPos(self.old_span.start));
        const old_end_byte: u32 = @intCast(buffer.cursorToPos(self.old_span.end));
        const new_end_byte: u32 = if (self.new_span) |new_span| @intCast(buffer.cursorToPos(new_span.end)) else old_end_byte;
        return .{
            .start_byte = start_byte,
            .old_end_byte = old_end_byte,
            .new_end_byte = new_end_byte,
            .start_point = start_point,
            .old_end_point = old_end_point,
            .new_end_point = new_end_point,
        };
    }
};
