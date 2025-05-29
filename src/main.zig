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

const color = enum(u8) {
    black = 1,
    white,
    red,
    green,
    blue,

    fn rgb_to_curses(x: u8) c_short {
        const f: f32 = @as(f32, @floatFromInt(x)) / 256 * 1000;
        return @intFromFloat(f);
    }

    pub fn init(self: color, r: u8, g: u8, b: u8) void {
        _ = nc.init_color(@intFromEnum(self), rgb_to_curses(r), rgb_to_curses(g), rgb_to_curses(b));
    }
};

const color_pair = enum(u8) {
    text = 1,
    keyword,
    string,
    number,

    pub fn init(self: color_pair, fg: color, bg: color) void {
        _ = nc.init_pair(@intFromEnum(self), @intFromEnum(fg), @intFromEnum(bg));
    }

    pub fn to_pair(self: color_pair) c_int {
        return @as(c_int, @intFromEnum(self)) * 256;
    }
};

const attr = .{
    .text = color_pair.text.to_pair(),
    .keyword = color_pair.keyword.to_pair() | nc.A_BOLD,
    .string = color_pair.string.to_pair(),
    .number = color_pair.number.to_pair(),
};

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

fn init_curses() !*nc.WINDOW {
    const win = nc.initscr() orelse return error.InitScr;
    _ = nc.noecho();

    if (nc.has_colors()) {
        _ = nc.start_color();
    }

    color.black.init(0, 0, 0);
    color.white.init(255, 255, 255);
    color.red.init(255, 0, 0);
    color.green.init(0, 255, 0);
    color.blue.init(0, 0, 255);

    color_pair.text.init(color.white, color.black);
    color_pair.keyword.init(color.red, color.black);
    color_pair.string.init(color.green, color.black);
    color_pair.number.init(color.blue, color.black);

    _ = nc.bkgd(@intCast(color_pair.text.to_pair()));

    return win;
}

fn redraw(buffer: *const Buffer, spans: *const std.ArrayList(SpanNodeTypeTuple)) void {
    var byte: usize = 0;
    for (0..buffer.items.len) |row| {
        var line: []u8 = buffer.items[row].items;
        // TODO: why this is necessary
        if (line.len == 0) line = "";

        for (0..line.len) |col| {
            const ch = line[col];
            var ch_attr = attr.text;
            for (spans.items) |span| {
                if (span.span.start_byte <= byte and span.span.end_byte > byte) {
                    if (std.mem.eql(u8, span.node_type, "return") or
                        std.mem.eql(u8, span.node_type, "primitive_type") or
                        std.mem.eql(u8, span.node_type, "#include"))
                    {
                        ch_attr = attr.keyword;
                        break;
                    }
                    if (std.mem.eql(u8, span.node_type, "system_lib_string") or
                        std.mem.eql(u8, span.node_type, "string_literal"))
                    {
                        ch_attr = attr.string;
                        break;
                    }
                    if (std.mem.eql(u8, span.node_type, "number_literal")) {
                        ch_attr = attr.number;
                        break;
                    }
                }
            }
            _ = nc.attrset(ch_attr);
            _ = nc.mvaddch(@intCast(row), @intCast(col), ch);
            byte += 1;
        }
        byte += 1;
    }

    _ = nc.standend();
    _ = nc.refresh();
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
    defer ts.ts_parser_delete(parser);
    var language_lib = try dl.open("/usr/lib/tree_sitter/c.so");
    var language: *const fn () *ts.struct_TSLanguage = undefined;
    language = language_lib.lookup(@TypeOf(language), "tree_sitter_c") orelse return error.NoSymbol;
    _ = ts.ts_parser_set_language(parser, language());

    const tree = ts.ts_parser_parse_string(parser, null, @ptrCast(content), @intCast(content.len));
    defer ts.ts_tree_delete(tree);
    const root_node = ts.ts_tree_root_node(tree);
    std.debug.print("tree: {s}\n", .{@as([*:0]u8, ts.ts_node_string(root_node))});

    const spans = try make_spans(root_node, allocator);
    // for (spans.items) |span| {
    //     std.debug.print("{s}\n", .{span.node_type});
    // }

    std.debug.print("AAAAAA {} {}\n", .{ nc.COLOR_PAIR(1), color_pair.text.to_pair() });
    const win = try init_curses();
    _ = win;

    redraw(&buffer, &spans);
    _ = nc.move(0, 0);

    while (true) {
        const key = nc.getch();
        if (key == 'q') {
            _ = nc.endwin();
            return;
        }
    }
}
