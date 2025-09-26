const std = @import("std");
const File = std.fs.File;

const buf = @import("buffer.zig");
const co = @import("color.zig");
const core = @import("core.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const ter = @import("terminal.zig");
const uni = @import("unicode.zig");
const cli = @import("cli.zig");
const ur = @import("uri.zig");

pub const HighlightConfig = struct {
    term_height: usize,
    highlight_line: usize,

    pub fn fromArgs(args: cli.Args) !?HighlightConfig {
        if (args.highlight_line == null) return null;
        return .{
            .highlight_line = args.highlight_line.?,
            .term_height = args.term_height orelse (try ter.terminalSize()).height,
        };
    }
};

pub fn printBuffer(buffer: *buf.Buffer, writer: *std.io.Writer, highlight: ?HighlightConfig) !void {
    var attrs_buf = std.mem.zeroes([128]u8);
    var attrs_writer = std.io.Writer.fixed(&attrs_buf);
    var attrs: []const u8 = undefined;
    var last_attrs_buf = std.mem.zeroes([128]u8);
    var last_attrs: ?[]const u8 = null;

    var start_row: i32 = 0;
    var end_row: i32 = @intCast(buffer.line_positions.items.len);
    if (highlight) |hi| {
        const half_term: i32 = @divFloor(@as(i32, @intCast(hi.term_height)), 2);
        start_row = @as(i32, @intCast(hi.highlight_line)) - half_term;
        end_row = @min(end_row, start_row + @as(i32, @intCast(hi.term_height)));
    }

    var span_index: usize = 0;
    var row: i32 = start_row;
    while (row < end_row) {
        if (row < 0) {
            row += 1;
            writer.writeAll("\n") catch {};
            continue;
        }
        defer {
            last_attrs = null;
            row += 1;
            writer.writeAll("\x1b[0m") catch {};
            if (buffer.lineTerminated(@intCast(row))) writer.writeAll("\n") catch {};
        }

        const line = buffer.lineContent(@intCast(row));
        var byte: usize = buffer.lineStart(@intCast(row));

        for (line) |ch| {
            _ = attrs_writer.consumeAll();
            if (buffer.ts_state) |ts_state| {
                if (ts_state.highlight) |hi| {
                    const highlight_spans = hi.spans.items;
                    const ch_attrs: []const co.Attr = b: while (span_index < highlight_spans.len) {
                        const span = highlight_spans[span_index];
                        if (span.span.start > byte) break :b co.Attributes.text;
                        if (byte >= span.span.start and byte < span.span.end) {
                            break :b span.attrs;
                        }
                        span_index += 1;
                    } else {
                        break :b co.Attributes.text;
                    };
                    try co.Attributes.write(ch_attrs, &attrs_writer);
                }
            }

            const hi_line = highlight != null and row == highlight.?.highlight_line;
            if (hi_line) try co.Attributes.write(co.Attributes.selection, &attrs_writer);

            attrs = attrs_writer.buffered();
            if (last_attrs == null or !std.mem.eql(u8, attrs, last_attrs.?)) {
                if (buffer.ts_state != null) writer.writeAll("\x1b[0m") catch {};
                try writer.writeAll(attrs);
                @memcpy(&last_attrs_buf, &attrs_buf);
                last_attrs = last_attrs_buf[0..attrs.len];
            }
            std.debug.assert(ch != '\n');
            try uni.unicodeToBytesWrite(writer, &.{ch});
            byte += try std.unicode.utf8CodepointSequenceLength(ch);
        }
    }
    try writer.flush();
}

fn createTmpFiles() !void {
    const tmp_file = try std.fs.cwd().createFile("/tmp/hat_e2e.txt", .{ .truncate = true });
    defer tmp_file.close();
    try tmp_file.writeAll(
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    );
}

test "printer no ts" {
    try createTmpFiles();

    main.std_err_file_writer = main.std_err.writer(&main.std_err_buf);
    log.log_writer = &main.std_err_file_writer.interface;

    const allocator = std.testing.allocator;
    var buffer = try buf.Buffer.init(allocator, try ur.fromRelativePath(allocator, "/tmp/hat_e2e.txt"));
    defer buffer.deinit();
    if (buffer.ts_state) |*ts| ts.deinit();
    buffer.ts_state = null;

    var content_writer = std.io.Writer.Allocating.init(allocator);
    defer content_writer.deinit();
    const writer = &content_writer.writer;

    try printBuffer(&buffer, writer, null);

    try std.testing.expectEqualStrings(
        "const std = @import(\"std\");\x1b[0m\n" ++
            "pub fn main() !void {\x1b[0m\n" ++
            "    std.debug.print(\"hello!\\n\", .{});\x1b[0m\n" ++
            "}\x1b[0m\n",
        content_writer.written(),
    );
}

test "printer no ts highlight" {
    try createTmpFiles();

    main.std_err_file_writer = main.std_err.writer(&main.std_err_buf);
    log.log_writer = &main.std_err_file_writer.interface;

    const allocator = std.testing.allocator;
    var buffer = try buf.Buffer.init(allocator, try ur.fromRelativePath(allocator, "/tmp/hat_e2e.txt"));
    defer buffer.deinit();
    if (buffer.ts_state) |*ts| ts.deinit();
    buffer.ts_state = null;

    var content_writer = std.io.Writer.Allocating.init(allocator);
    defer content_writer.deinit();
    const writer = &content_writer.writer;

    try printBuffer(&buffer, writer, .{ .term_height = 10, .highlight_line = 2 });

    try std.testing.expectEqualStrings(
        "\n\n\n" ++
            "const std = @import(\"std\");\x1b[0m\n" ++
            "pub fn main() !void {\x1b[0m\n" ++
            "\x1b[48;2;62;62;67m    std.debug.print(\"hello!\\n\", .{});\x1b[0m\n" ++
            "}\x1b[0m\n",
        content_writer.written(),
    );
}
