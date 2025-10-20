const std = @import("std");

const buf = @import("buffer.zig");
const lsp = @import("lsp.zig");
const reg = @import("regex.zig");
const ts = @import("ts.zig");

pub const Cursor = struct {
    row: i32 = 0,
    col: i32 = 0,

    pub fn applyOffset(self: Cursor, offset: Cursor) Cursor {
        return .{ .row = self.row + offset.row, .col = self.col + offset.col };
    }

    pub fn negate(self: Cursor) Cursor {
        return .{
            .row = -self.row,
            .col = -self.col,
        };
    }

    pub fn order(self: Cursor, other: Cursor) std.math.Order {
        if (std.meta.eql(self, other)) return .eq;
        if (self.row == other.row) {
            return std.math.order(self.col, other.col);
        }
        return std.math.order(self.row, other.row);
    }

    pub fn fromLsp(position: lsp.types.Position) Cursor {
        return .{
            .row = @intCast(position.line),
            .col = @intCast(position.character),
        };
    }

    pub fn toLsp(self: Cursor) lsp.types.Position {
        return .{
            .line = @intCast(self.row),
            .character = @intCast(self.col),
        };
    }

    pub fn toTs(self: Cursor) ts.ts.TSPoint {
        return .{
            .row = @intCast(self.row),
            .column = @intCast(self.col),
        };
    }
};

/// End position is exclusive
/// To include \n, .end = .{.row = row + 1, .col = 0}
pub const Span = struct {
    start: Cursor,
    end: Cursor,

    pub fn inRange(self: Span, pos: Cursor) bool {
        const start = self.start.order(pos);
        const end = self.end.order(pos);
        return start != .gt and end == .gt;
    }

    pub fn fromLsp(position: lsp.types.Range) Span {
        return .{
            .start = Cursor.fromLsp(position.start),
            .end = Cursor.fromLsp(position.end),
        };
    }

    pub fn toLsp(self: Span) lsp.types.Range {
        return .{
            .start = self.start.toLsp(),
            .end = self.end.toLsp(),
        };
    }

    pub fn fromSpanFlat(buffer: *const buf.Buffer, byte_span: SpanFlat) Span {
        return .{
            .start = buffer.posToCursor(byte_span.start),
            .end = buffer.posToCursor(byte_span.end),
        };
    }
};

pub const SpanFlat = struct {
    start: usize,
    end: usize,

    pub fn init(span: SpanFlat, capture_name: []const u8) ?SpanFlat {
        if (!std.mem.eql(u8, capture_name, "name")) return null;
        return span;
    }

    pub fn fromBufSpan(buffer: *const buf.Buffer, span: Span) SpanFlat {
        return .{
            .start = buffer.cursorToPos(span.start),
            .end = buffer.cursorToPos(span.end),
        };
    }

    pub fn fromRegex(match: reg.RegexMatch) SpanFlat {
        return .{ .start = match.getStartAt(0).?, .end = match.getEndAt(0).? };
    }

    pub fn inRange(self: SpanFlat, pos: usize) bool {
        return self.start <= pos and pos < self.end;
    }
};

pub const Layout = struct {
    number_line: Area,
    buffer: Area,
};

pub const Area = struct {
    pos: Cursor,
    dims: Dimensions,
};

pub const Dimensions = struct {
    width: usize,
    height: usize,
};

pub const FatalError = error{OutOfMemory};
