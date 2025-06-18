const std = @import("std");

pub const RgbColor = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn from_hex(hex: u24) RgbColor {
        return .{
            .r = (hex >> 16) & 0xff,
            .g = (hex >> 8) & 0xff,
            .b = (hex >> 0) & 0xff,
        };
    }

    pub fn write(self: RgbColor, writer: anytype, fg: bool) !void {
        const fgbg: u8 = if (fg) 38 else 48;
        try std.fmt.format(writer, "\x1b[{};2;{};{};{}m", .{ fgbg, self.r, self.g, self.b });
    }
};

pub const color = enum {
    pub const black = RgbColor.from_hex(0x000000);
    pub const gray1 = RgbColor.from_hex(0x282828);
    pub const gray2 = RgbColor.from_hex(0x505050);
    pub const white = RgbColor.from_hex(0xffffff);
    pub const red = RgbColor.from_hex(0xf57171);
    pub const green = RgbColor.from_hex(0xa6d189);
    pub const blue = RgbColor.from_hex(0x9aa3f5);
    pub const yellow = RgbColor.from_hex(0xe6b99d);
    pub const magenta = RgbColor.from_hex(0xe29eca);
};

pub const Attr = union(enum) {
    fg: RgbColor,
    bg: RgbColor,

    pub fn write(self: Attr, writer: anytype) !void {
        switch (self) {
            .fg => |fg_c| try fg_c.write(writer, true),
            .bg => |bg_c| try bg_c.write(writer, false),
        }
    }
};

pub const attributes = enum {
    pub const text = &[_]Attr{.{ .fg = color.white }};
    pub const selection = &[_]Attr{.{ .bg = color.gray2 }};
    pub const keyword = &[_]Attr{.{ .fg = color.magenta }};
    pub const string = &[_]Attr{.{ .fg = color.green }};
    pub const number = &[_]Attr{.{ .fg = color.yellow }};

    pub fn write(attrs: []Attr, writer: anytype) !void {
        for (attrs) |attr| {
            try attr.write(writer);
        }
    }
};

pub const term_fg: ?RgbColor = color.white;
pub const term_bg: ?RgbColor = null;
