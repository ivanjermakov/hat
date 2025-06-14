const c = @cImport({
    @cInclude("ncurses.h");
});

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
        _ = c.init_color(@intFromEnum(self), rgb_to_curses(r), rgb_to_curses(g), rgb_to_curses(b));
    }
};

pub const ColorPair = enum(u8) {
    text = 1,
    keyword,
    string,
    number,

    pub fn init(self: ColorPair, fg: Color, bg: Color) void {
        _ = c.init_pair(@intFromEnum(self), @intFromEnum(fg), @intFromEnum(bg));
    }

    pub fn to_pair(self: ColorPair) c_int {
        return @as(c_int, @intFromEnum(self)) * 256;
    }
};

pub const Attr = .{
    .text = ColorPair.text.to_pair(),
    .keyword = ColorPair.keyword.to_pair() | c.A_BOLD,
    .string = ColorPair.string.to_pair(),
    .number = ColorPair.number.to_pair(),
};

pub fn init_color() void {
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
}
