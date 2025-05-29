const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});
const dl = std.DynLib;
const nc = @cImport({
    @cInclude("ncurses.h");
});

const Buffer = std.ArrayList(Line);

const Line = std.ArrayList(u8);

fn buffer_new(content: []u8, alloc: std.mem.Allocator) !Buffer {
    var lines_iter = std.mem.split(u8, content, "\n");
    var lines: Buffer = std.ArrayList(Line).init(alloc);
    while (true) {
        const next: []u8 = @constCast(lines_iter.next() orelse break);
        var line = std.ArrayList(u8).init(alloc);
        try line.appendSlice(next);
        try lines.append(line);
    }
    return lines;
}

const Span = struct {
    start_byte: usize,
    end_byte: usize,
};

const NodeType = []u8;

const SpanNodeTypeTuple = struct {
    span: Span,
    node_type: NodeType,
};

fn make_spans(root_node: ts.struct_TSNode, alloc: std.mem.Allocator) !std.ArrayList(SpanNodeTypeTuple) {
    var spans = std.ArrayList(SpanNodeTypeTuple).init(alloc);
    var cursor = ts.ts_tree_cursor_new(root_node);
    var node = root_node;

    traverse: while (true) {
        const node_type = std.mem.span(ts.ts_node_type(node));
        if (node_type.len == 0) continue;

        const start_byte = ts.ts_node_start_byte(node);
        const end_byte = ts.ts_node_end_byte(node);
        const span = .{ .start_byte = start_byte, .end_byte = end_byte };
        try spans.append(.{ .span = span, .node_type = @constCast(node_type) });

        if (ts.ts_tree_cursor_goto_first_child(&cursor)) {
            node = ts.ts_tree_cursor_current_node(&cursor);
        } else {
            while (true) {
                if (ts.ts_tree_cursor_goto_next_sibling(&cursor)) {
                    node = ts.ts_tree_cursor_current_node(&cursor);
                    break;
                } else {
                    if (ts.ts_tree_cursor_goto_parent(&cursor)) {
                        node = ts.ts_tree_cursor_current_node(&cursor);
                    } else {
                        break :traverse;
                    }
                }
            }
        }
    }

    return spans;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse return error.NoPath;

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });

    var buf: []u8 = try allocator.alloc(u8, 2048);
    const file_len = try file.readAll(buf);
    const content = buf[0..file_len];
    const buffer = try buffer_new(content, allocator);

    const parser = ts.ts_parser_new();
    var language_lib = try dl.open("/usr/lib/tree_sitter/c.so");
    var language: *const fn () *ts.struct_TSLanguage = undefined;
    language = language_lib.lookup(@TypeOf(language), "tree_sitter_c") orelse return error.NoSymbol;
    _ = ts.ts_parser_set_language(parser, language());

    const tree = ts.ts_parser_parse_string(parser, null, @ptrCast(content), @intCast(content.len));
    const root_node = ts.ts_tree_root_node(tree);
    std.debug.print("tree: {s}\n", .{@as([*:0]u8, ts.ts_node_string(root_node))});

    const spans = try make_spans(root_node, allocator);

    const byte = 0;
    for (spans.items) |span| {
        if (span.span.start_byte <= byte and span.span.end_byte > byte) {
            std.debug.print("{s}\n", .{span.node_type});
        }
    }

    const win = nc.initscr();

    for (0..buffer.items.len) |i| {
        var line: []u8 = buffer.items[i].items;
        // TODO: why this is necessary
        if (line.len == 0) line = "";
        _ = nc.mvwaddstr(win, @intCast(i), 0, @ptrCast(line));
    }

    _ = nc.wmove(win, 0, 0);
    _ = nc.refresh();

    while (true) {
        const key = nc.getch();
        if (key == 'q') {
            _ = nc.endwin();
            return;
        }
    }

    ts.ts_tree_delete(tree);
    ts.ts_parser_delete(parser);
}
