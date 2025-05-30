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

pub const Line = std.ArrayList(u8);

pub const Color = enum(i16) {
    none = -1,
    black = 1,
    white,
    red,
    green,
    blue,
    yellow,
    orange,
    magenta,

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

const Span = struct {
    start_byte: usize,
    end_byte: usize,
};

const NodeType = []u8;

const SpanNodeTypeTuple = struct {
    span: Span,
    node_type: NodeType,
};

pub const allocator = std.heap.page_allocator;
pub var buffer: Buffer = std.ArrayList(Line).init(allocator);
pub var spans: std.ArrayList(SpanNodeTypeTuple) = std.ArrayList(SpanNodeTypeTuple).init(allocator);
pub var content: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
pub var cursor: Cursor = .{ .row = 0, .col = 0 };
pub var parser: ?*ts.TSParser = null;
pub var tree: ?*ts.TSTree = null;
pub var needs_redraw = false;
pub var needs_reparse = false;

fn update_buffer() !void {
    buffer.clearRetainingCapacity();
    var lines_iter = std.mem.splitSequence(u8, content.items, "\n");
    while (true) {
        const next: []u8 = @constCast(lines_iter.next() orelse break);
        var line = std.ArrayList(u8).init(allocator);
        try line.appendSlice(next);
        try buffer.append(line);
    }
}

fn buffer_content() !void {
    content.clearRetainingCapacity();
    for (buffer.items) |line| {
        try content.appendSlice(line.items);
        try content.append('\n');
    }
}

fn make_spans() !void {
    const root_node = ts.ts_tree_root_node(tree);
    spans.clearRetainingCapacity();
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
    Color.yellow.init(255, 255, 0);
    Color.orange.init(230, 185, 157);
    Color.magenta.init(211, 168, 239);

    ColorPair.text.init(Color.white, Color.none);
    ColorPair.keyword.init(Color.magenta, Color.none);
    ColorPair.string.init(Color.green, Color.none);
    ColorPair.number.init(Color.orange, Color.none);

    _ = nc.bkgd(@intCast(ColorPair.text.to_pair()));

    return win;
}

fn init_parser() !void {
    parser = ts.ts_parser_new();
    var language_lib = try dl.open("/usr/lib/tree_sitter/c.so");
    var language: *const fn () *ts.struct_TSLanguage = undefined;
    language = language_lib.lookup(@TypeOf(language), "tree_sitter_c") orelse return error.NoSymbol;
    _ = ts.ts_parser_set_language(parser, language());
}

fn ts_parse() !void {
    try buffer_content();
    if (tree) |old_tree| ts.ts_tree_delete(old_tree);
    tree = ts.ts_parser_parse_string(parser, null, @ptrCast(content.items), @intCast(content.items.len));
}

fn redraw() void {
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
    _ = nc.move(@intCast(cursor.row), @intCast(cursor.col));
}

pub fn main() !void {
    defer dispose();

    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse return error.NoPath;

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });

    const file_content = mk_content: {
        var buf: []u8 = try allocator.alloc(u8, 2048);
        const file_len = try file.readAll(buf);
        break :mk_content buf[0..file_len];
    };
    try content.appendSlice(file_content);
    try update_buffer();

    const win = try init_curses();
    _ = win;

    try init_parser();

    try ts_parse();
    try make_spans();
    redraw();

    while (true) {
        _ = nc.refresh();
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
        if (needs_reparse) {
            try ts_parse();
            try make_spans();
        }
        if (needs_redraw) {
            redraw();
        }
    }
}

fn dispose() void {
    defer ts.ts_parser_delete(parser);
    defer buffer.clearAndFree();
}
