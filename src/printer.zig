const std = @import("std");

const buf = @import("buffer.zig");
const co = @import("color.zig");
const core = @import("core.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const ter = @import("terminal.zig");
const uni = @import("unicode.zig");

pub const HighlightConfig = struct {
    term_height: usize,
    highlight_line: usize,

    pub fn fromArgs(args: main.Args) !?HighlightConfig {
        if (args.highlight_line == null) return null;
        return .{
            .highlight_line = args.highlight_line.?,
            .term_height = args.term_height orelse (try ter.terminalSize()).height,
        };
    }
};

pub fn printBuffer(buffer: *buf.Buffer, writer: *std.io.Writer, highlight: ?HighlightConfig) !void {
    var attrs_buf = std.mem.zeroes([128]u8);
    var attrs_stream = std.io.fixedBufferStream(&attrs_buf);
    var attrs: []const u8 = undefined;
    var last_attrs_buf = std.mem.zeroes([128]u8);
    var last_attrs: ?[]const u8 = null;

    var start_row: i32 = 0;
    var end_row: i32 = @intCast(buffer.line_positions.items.len);
    if (highlight) |hi| {
        const half_term: i32 = @divFloor(@as(i32, @intCast(hi.term_height)), 2);
        start_row = @as(i32, @intCast(hi.highlight_line)) - half_term;
        end_row = start_row + @as(i32, @intCast(hi.term_height));
    }

    var span_index: usize = 0;
    var row: i32 = start_row;
    while (row < end_row) {
        defer {
            _ = writer.write("\x1b[0m") catch {};
            _ = writer.write("\n") catch {};
            last_attrs = null;
            row += 1;
        }
        if (row < 0 or row >= buffer.line_positions.items.len) continue;
        const line = buffer.lineContent(@intCast(row));

        var byte: usize = buffer.lineStart(@intCast(row));

        for (line) |ch| {
            attrs_stream.reset();
            if (buffer.ts_state) |ts_state| {
                const highlight_spans = ts_state.highlight.spans.items;
                const ch_attrs: []const co.Attr = b: while (span_index < highlight_spans.len) {
                    const span = highlight_spans[span_index];
                    if (span.span.start > byte) break :b co.attributes.text;
                    if (byte >= span.span.start and byte < span.span.end) {
                        break :b span.attrs;
                    }
                    span_index += 1;
                } else {
                    break :b co.attributes.text;
                };
                try co.attributes.write(ch_attrs, attrs_stream.writer());
            }

            if (highlight != null and row == highlight.?.highlight_line) {
                try co.attributes.write(co.attributes.selection, attrs_stream.writer());
            }

            attrs = attrs_stream.getWritten();
            if (last_attrs == null or !std.mem.eql(u8, attrs, last_attrs.?)) {
                _ = try writer.write("\x1b[0m");
                _ = try writer.write(attrs);
                @memcpy(&last_attrs_buf, &attrs_buf);
                last_attrs = last_attrs_buf[0..try attrs_stream.getPos()];
            }

            try uni.unicodeToBytesWrite(writer, &.{ch});

            byte += try std.unicode.utf8CodepointSequenceLength(ch);
        }
    }
    try writer.flush();
}
