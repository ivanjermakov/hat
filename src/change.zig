const std = @import("std");
const Allocator = std.mem.Allocator;

const reg = @import("regex");

const buf = @import("buffer.zig");
const core = @import("core.zig");
const Cursor = core.Cursor;
const Span = core.Span;
const ByteSpan = core.ByteSpan;
const lsp = @import("lsp.zig");
const ts = @import("ts.zig");
const uni = @import("unicode.zig");

pub const Change = struct {
    old_span: Span,
    old_byte_span: ByteSpan,
    old_text: []const u21,
    new_span: ?Span = null,
    new_byte_span: ?ByteSpan = null,
    new_text: ?[]const u21 = null,
    allocator: Allocator,

    pub fn initInsert(
        allocator: Allocator,
        buffer: *const buf.Buffer,
        pos: Cursor,
        new_text: []const u21,
    ) !Change {
        return initReplace(allocator, buffer, .{ .start = pos, .end = pos }, new_text);
    }

    pub fn initDelete(allocator: Allocator, buffer: *const buf.Buffer, span: Span) !Change {
        return initReplace(allocator, buffer, span, &.{});
    }

    pub fn initReplace(
        allocator: Allocator,
        buffer: *const buf.Buffer,
        span: Span,
        new_text: []const u21,
    ) !Change {
        return .{
            .old_span = span,
            .old_byte_span = ByteSpan.fromBufSpan(buffer, span),
            .old_text = try allocator.dupe(u21, buffer.textAt(span)),
            .new_text = try allocator.dupe(u21, new_text),
            .allocator = allocator,
        };
    }

    pub fn fromLsp(allocator: Allocator, buffer: *const buf.Buffer, edit: lsp.types.TextEdit) !Change {
        const span = Span.fromLsp(edit.range);
        const new_text = try uni.unicodeFromBytes(allocator, edit.newText);
        defer allocator.free(new_text);
        return initReplace(allocator, buffer, span, new_text);
    }

    pub fn deinit(self: *Change) void {
        self.allocator.free(self.old_text);
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
        _ = try writer.write(" \"");
        for (self.old_text) |ch| try std.fmt.format(writer, "{u}", .{ch});
        _ = try writer.write("\"");

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
            .old_byte_span = self.new_byte_span.?,
            .new_span = self.old_span,
            .new_byte_span = self.old_byte_span,
            .new_text = try self.allocator.dupe(u21, self.old_text),
            .old_text = try self.allocator.dupe(u21, self.new_text.?),
            .allocator = self.allocator,
        };
    }

    pub fn clone(self: *const Change, allocator: Allocator) !Change {
        var cloned = self.*;
        if (self.new_text) |t| cloned.new_text = try allocator.dupe(u21, t);
        cloned.old_text = try allocator.dupe(u21, self.old_text);
        return cloned;
    }

    pub fn toLsp(self: *const Change, allocator: Allocator) !lsp.types.TextDocumentContentChangeEvent {
        const text = try uni.unicodeToBytes(allocator, self.new_text orelse &.{});
        return .{
            .literal_0 = .{
                .range = self.old_span.toLsp(),
                .text = text,
            },
        };
    }

    pub fn toTs(self: *const Change) ts.ts.TSInputEdit {
        const start_point = self.old_span.start.toTs();
        const old_end_point = self.old_span.end.toTs();
        const new_end_point = if (self.new_span) |new_span| new_span.end.toTs() else old_end_point;
        const start_byte: u32 = @intCast(self.old_byte_span.start);
        const old_end_byte: u32 = @intCast(self.old_byte_span.end);
        const new_end_byte: u32 = @intCast(self.new_byte_span.?.end);
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
