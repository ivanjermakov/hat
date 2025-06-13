const std = @import("std");
const posix = std.posix;
const loc = @cImport({
    @cInclude("locale.h");
});
const termios = @cImport({
    @cInclude("termios.h");
});
const dl = std.DynLib;
const nc = @cImport({
    @cInclude("ncurses.h");
});
const action = @import("action.zig");
const input = @import("input.zig");
const unicode = @import("unicode.zig");
const ft = @import("file_type.zig");
const buf = @import("buffer.zig");

pub const Cursor = struct {
    row: i32,
    col: i32,
};

pub const Color = enum(i16) {
    none = -1,
    black = 1,
    white,
    red,
    green,
    blue,
    yellow,
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

const Mode = enum {
    normal,
    insert,
};

const Args = struct {
    path: ?[]u8,
    log: bool,
};

pub const sleep_ns = 16 * 1e6;
pub const allocator = std.heap.page_allocator;
pub const std_out = std.io.getStdOut();

pub var buffer: buf.Buffer = undefined;
pub var cursor: Cursor = .{ .row = 0, .col = 0 };
pub var mode = Mode.normal;
pub var needs_redraw = false;
pub var needs_reparse = false;
pub var log_enabled = true;
pub var args: Args = .{
    .path = null,
    .log = false,
};

fn init_curses() !*nc.WINDOW {
    const win = nc.initscr() orelse return error.InitScr;
    _ = nc.use_default_colors();
    _ = nc.noecho();
    _ = loc.setlocale(loc.LC_ALL, "");

    if (nc.has_colors()) {
        _ = nc.start_color();
    }

    Color.black.init(0, 0, 0);
    Color.white.init(255, 255, 255);
    Color.red.init(245, 113, 113);
    Color.green.init(166, 209, 137);
    Color.blue.init(154, 163, 245);
    Color.yellow.init(230, 185, 157);
    Color.magenta.init(211, 168, 239);

    ColorPair.text.init(Color.white, Color.none);
    ColorPair.keyword.init(Color.magenta, Color.none);
    ColorPair.string.init(Color.green, Color.none);
    ColorPair.number.init(Color.yellow, Color.none);

    _ = nc.bkgd(@intCast(ColorPair.text.to_pair()));

    return win;
}

fn redraw() !void {
    _ = nc.erase();

    var byte: usize = 0;
    for (0..buffer.content.items.len) |row| {
        const line: []u8 = buffer.content.items[row].items;
        const line_view = try std.unicode.Utf8View.init(line);
        var line_iter = line_view.iterator();

        var col: usize = 0;
        while (line_iter.nextCodepoint()) |ch| {
            var ch_attr = Attr.text;
            for (buffer.spans.items) |span| {
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
            const cchar = unicode.codepoint_to_cchar(ch);
            _ = nc.mvadd_wch(@intCast(row), @intCast(col), @ptrCast(&cchar));
            byte += try std.unicode.utf8CodepointSequenceLength(ch);
            col += 1;
        }
        byte += 1;
    }

    _ = nc.standend();
    _ = nc.move(@intCast(cursor.row), @intCast(cursor.col));

    switch (mode) {
        .normal => _ = try std_out.write(input.cursor_type.steady_block),
        .insert => _ = try std_out.write(input.cursor_type.steady_bar),
    }
}

fn setup_terminal() !void {
    var tty: termios.struct_termios = undefined;
    _ = termios.tcgetattr(std.posix.STDIN_FILENO, &tty);
    tty.c_lflag &= @bitCast(~(termios.ICANON | termios.ECHO));
    _ = termios.tcsetattr(std.posix.STDIN_FILENO, termios.TCSANOW, &tty);

    _ = try posix.fcntl(0, posix.F.SETFL, try posix.fcntl(0, posix.F.GETFL, 0) | posix.SOCK.NONBLOCK);
}

fn get_codes() !?[]u8 {
    var in_buf = std.ArrayList(u8).init(allocator);
    while (true) {
        var b: [1]u8 = undefined;
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, b[0..1]) catch break;
        if (bytes_read == 0) break;
        try in_buf.appendSlice(b[0..]);
        // 1ns seems to be enough wait time for stdin to fill up with the next code
        std.Thread.sleep(1);
    }
    if (in_buf.items.len == 0) return null;

    if (log_enabled) {
        std.debug.print("input: ", .{});
        for (in_buf.items) |code| {
            std.debug.print("{s}", .{try input.ansi_code_to_string(code)});
        }
        std.debug.print("\n", .{});
    }

    return in_buf.items;
}

fn get_keys(codes: []u8) ![]input.Key {
    var keys = std.ArrayList(input.Key).init(allocator);

    var cs = std.ArrayList(u8).init(allocator);
    try cs.appendSlice(codes);

    while (cs.items.len > 0) {
        const key = input.parse_ansi(&cs) catch |e| {
            if (log_enabled) std.debug.print("{}\n", .{e});
            continue;
        };
        try keys.append(key);
    }
    return keys.items;
}

pub fn main() !void {
    defer deinit();
    try ft.init_file_types();

    var cmd_args = std.process.args();
    _ = cmd_args.skip();
    while (cmd_args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            args.log = true;
            continue;
        }
        args.path = @constCast(arg);
    }
    log_enabled = args.log;

    const path = args.path orelse return error.NoPath;
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    buffer = try buf.Buffer.init(allocator, file_content);
    defer buffer.deinit();
    try buffer.ts_parse();
    try buffer.make_spans();

    try setup_terminal();
    const win = try init_curses();
    _ = win;

    try redraw();

    while (true) {
        _ = nc.refresh();
        std.time.sleep(sleep_ns);

        const codes = try get_codes() orelse continue;
        const keys = try get_keys(codes);
        if (keys.len == 0) continue;
        needs_redraw = true;

        for (keys) |key| {
            const code = key.code;
            var ch: ?u8 = null;
            if (key.printable != null and key.printable.?.len == 1) ch = key.printable.?[0];

            if (code == .up) cursor.row -= 1;
            if (code == .down) cursor.row += 1;
            if (code == .left) cursor.col -= 1;
            if (code == .right) cursor.col += 1;
            switch (mode) {
                .normal => {
                    if (ch == 'q') return;
                    if (ch == 'i') cursor.row -= 1;
                    if (ch == 'k') cursor.row += 1;
                    if (ch == 'j') cursor.col -= 1;
                    if (ch == 'l') cursor.col += 1;
                    if (ch == 'h') mode = .insert;
                },
                .insert => {
                    if (code == .escape) mode = .normal;
                    if (code == .delete) {
                        try action.remove_char();
                        needs_reparse = true;
                    }
                    if (code == .backspace) {
                        try action.remove_prev_char();
                        needs_reparse = true;
                    }
                    if (code == .enter) {
                        try action.insert_newline();
                        needs_reparse = true;
                    }
                    if (key.printable) |printable| {
                        try action.insert_text(printable);
                        needs_reparse = true;
                    }
                },
            }
        }
        action.validate_cursor();
        if (needs_reparse) {
            try buffer.ts_parse();
            try buffer.make_spans();
        }
        if (needs_redraw) {
            try redraw();
        }
    }
}

fn deinit() void {
    _ = nc.endwin();
    _ = std_out.write(input.cursor_type.steady_block) catch {};
}
