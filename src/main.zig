const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
});
const dl = std.DynLib;
const nc = @cImport({
    @cInclude("ncurses.h");
});
const action = @import("action.zig");

pub const Buffer = std.ArrayList(Line);

pub const Cursor = struct {
    row: i32,
    col: i32,
};
pub var cursor: Cursor = .{ .row = 0, .col = 0 };

pub var need_redraw = false;
pub var need_reparse = false;

pub const Line = std.ArrayList(u8);

pub const Color = enum(i16) {
    none = -1,
    black = 1,
    white,
    red,
    green,
    blue,

    fn rgb_to_curses(x: u8) c_short {
        const f: f32 = @as(f32, @floatFromInt(x)) / 256 * 1000;
        return @intFromFloat(f);
    }

    pub fn init(self: Color, r: u8, g: u8, b: u8) void {
        _ = nc.init_color(@intFromEnum(self), rgb_to_curses(r), rgb_to_curses(g), rgb_to_curses(b));
    }
};

pub const ColorPair = enum(u8) {
    text = 1,
    keyword,
    string,
    number,

    pub fn init(self: ColorPair, fg: Color, bg: Color) void {
        _ = nc.init_pair(@intFromEnum(self), @intFromEnum(fg), @intFromEnum(bg));
    }

    pub fn to_pair(self: ColorPair) c_int {
        return @as(c_int, @intFromEnum(self)) * 256;
    }
};

const Attr = .{
    .text = ColorPair.text.to_pair(),
    .keyword = ColorPair.keyword.to_pair() | nc.A_BOLD,
    .string = ColorPair.string.to_pair(),
    .number = ColorPair.number.to_pair(),
};

fn buffer_new(content: []u8, alloc: std.mem.Allocator) !Buffer {
    var lines_iter = std.mem.splitSequence(u8, content, "\n");
    var lines: Buffer = std.ArrayList(Line).init(alloc);
    while (true) {
        const next: []u8 = @constCast(lines_iter.next() orelse break);
        var line = std.ArrayList(u8).init(alloc);
        try line.appendSlice(next);
        try lines.append(line);
    }
    return lines;
}

fn buffer_content(buffer: *const Buffer, alloc: std.mem.Allocator) ![]u8 {
    var content = std.ArrayList(u8).init(alloc);
    for (buffer.items) |line| {
        try content.appendSlice(line.items);
        try content.append('\n');
    }
    return content.items;
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
    var tree_cursor = ts.ts_tree_cursor_new(root_node);
    var node = root_node;

    traverse: while (true) {
        const node_type = std.mem.span(ts.ts_node_type(node));
        if (node_type.len == 0) continue;

        const start_byte = ts.ts_node_start_byte(node);
        const end_byte = ts.ts_node_end_byte(node);
        try spans.append(.{
            .span = .{ .start_byte = start_byte, .end_byte = end_byte },
            .node_type = @constCast(node_type),
        });

        if (ts.ts_tree_cursor_goto_first_child(&tree_cursor)) {
            node = ts.ts_tree_cursor_current_node(&tree_cursor);
        } else {
            while (true) {
                if (ts.ts_tree_cursor_goto_next_sibling(&tree_cursor)) {
                    node = ts.ts_tree_cursor_current_node(&tree_cursor);
                    break;
                } else {
                    if (ts.ts_tree_cursor_goto_parent(&tree_cursor)) {
                        node = ts.ts_tree_cursor_current_node(&tree_cursor);
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
    _ = nc.use_default_colors();
    _ = nc.noecho();

    if (nc.has_colors()) {
        _ = nc.start_color();
    }

    Color.black.init(0, 0, 0);
    Color.white.init(255, 255, 255);
    Color.red.init(255, 0, 0);
    Color.green.init(0, 255, 0);
    Color.blue.init(0, 0, 255);

    ColorPair.text.init(Color.white, Color.none);
    ColorPair.keyword.init(Color.red, Color.none);
    ColorPair.string.init(Color.green, Color.none);
    ColorPair.number.init(Color.blue, Color.none);

    _ = nc.bkgd(@intCast(ColorPair.text.to_pair()));

    return win;
}

fn init_parser() !?*ts.TSParser {
    const parser = ts.ts_parser_new();
    var language_lib = try dl.open("/usr/lib/tree_sitter/c.so");
    var language: *const fn () *ts.struct_TSLanguage = undefined;
    language = language_lib.lookup(@TypeOf(language), "tree_sitter_c") orelse return error.NoSymbol;
    _ = ts.ts_parser_set_language(parser, language());
    return parser;
}

fn ts_parse(parser: ?*ts.TSParser, buffer: *const Buffer, allocator: std.mem.Allocator) !?*ts.TSTree {
    const content = try buffer_content(buffer, allocator);
    const tree = ts.ts_parser_parse_string(parser, null, @ptrCast(content), @intCast(content.len));
    return tree;
}

fn redraw(buffer: *const Buffer, spans: *const std.ArrayList(SpanNodeTypeTuple)) void {
    var byte: usize = 0;
    for (0..buffer.items.len) |row| {
        var line: []u8 = buffer.items[row].items;
        // TODO: why this is necessary
        if (line.len == 0) line = "";

        for (0..line.len) |col| {
            const ch = line[col];
            var ch_attr = Attr.text;
            for (spans.items) |span| {
                if (span.span.start_byte <= byte and span.span.end_byte > byte) {
                    if (std.mem.eql(u8, span.node_type, "return") or
                        std.mem.eql(u8, span.node_type, "primitive_type") or
                        std.mem.eql(u8, span.node_type, "#include"))
                    {
                        ch_attr = Attr.keyword;
                        break;
                    }
                    if (std.mem.eql(u8, span.node_type, "system_lib_string") or
                        std.mem.eql(u8, span.node_type, "string_literal"))
                    {
                        ch_attr = Attr.string;
                        break;
                    }
                    if (std.mem.eql(u8, span.node_type, "number_literal")) {
                        ch_attr = Attr.number;
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

fn update(parser: ?*ts.TSParser, buffer: *const Buffer, allocator: std.mem.Allocator) !void {
    const tree = try ts_parse(parser, buffer, allocator);
    defer ts.ts_tree_delete(tree);
    const root_node = ts.ts_tree_root_node(tree);
    // std.debug.print("tree: {s}\n", .{@as([*:0]u8, ts.ts_node_string(root_node))});
    const spans = try make_spans(root_node, allocator);
    // for (spans.items) |span| {
    //     std.debug.print("{s}\n", .{span.node_type});
    // }

    redraw(buffer, &spans);
    _ = nc.move(@intCast(cursor.row), @intCast(cursor.col));
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse return error.NoPath;

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });

    var buf: []u8 = try allocator.alloc(u8, 2048);
    const file_len = try file.readAll(buf);
    const buffer = try buffer_new(buf[0..file_len], allocator);

    const win = try init_curses();
    _ = win;

    const parser = try init_parser();
    defer ts.ts_parser_delete(parser);

    try update(parser, &buffer, allocator);

    while (true) {
        const key = nc.getch();
        if (key == 'q') {
            _ = nc.endwin();
            return;
        }
        if (key == 'i') {
            action.try_move_cursor(.{ .row = cursor.row - 1, .col = cursor.col });
        }
        if (key == 'k') {
            action.try_move_cursor(.{ .row = cursor.row + 1, .col = cursor.col });
        }
        if (key == 'j') {
            action.try_move_cursor(.{ .row = cursor.row, .col = cursor.col - 1 });
        }
        if (key == 'l') {
            action.try_move_cursor(.{ .row = cursor.row, .col = cursor.col + 1 });
        }
        if (need_redraw or need_reparse) {
            try update(parser, &buffer, allocator);
        }
    }
}
