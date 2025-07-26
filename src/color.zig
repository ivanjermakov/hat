const std = @import("std");

pub const RgbColor = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(hex: u24) RgbColor {
        return .{
            .r = (hex >> 16) & 0xff,
            .g = (hex >> 8) & 0xff,
            .b = (hex >> 0) & 0xff,
        };
    }

    pub fn toHexStr(self: RgbColor) [6]u8 {
        var buf = std.mem.zeroes([6]u8);
        _ = std.fmt.bufPrint(&buf, "{x}{x}{x}", .{ self.r, self.g, self.b }) catch {};
        return buf;
    }
};

pub const color = enum {
    pub const black = RgbColor.fromHex(0x000000);
    pub const gray1 = RgbColor.fromHex(0x1b1b1d);
    pub const gray2 = RgbColor.fromHex(0x2a2a2d);
    pub const gray3 = RgbColor.fromHex(0x3e3e43);
    pub const gray4 = RgbColor.fromHex(0x57575f);
    pub const gray5 = RgbColor.fromHex(0x757581);
    pub const gray6 = RgbColor.fromHex(0x9998a8);
    pub const gray7 = RgbColor.fromHex(0xc1c0d4);
    pub const white = RgbColor.fromHex(0xffffff);
    pub const red = RgbColor.fromHex(0xf57171);
    pub const green = RgbColor.fromHex(0xa6d189);
    pub const blue = RgbColor.fromHex(0x9aa3f5);
    pub const yellow = RgbColor.fromHex(0xe6b99d);
    pub const magenta = RgbColor.fromHex(0xd3a8ef);
};

pub const Attr = union(enum) {
    fg: RgbColor,
    bg: RgbColor,
    underline: RgbColor,
    curly_underline,

    pub fn write(self: Attr, writer: anytype) !void {
        switch (self) {
            .fg => |c| try std.fmt.format(writer, "\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .bg => |c| try std.fmt.format(writer, "\x1b[48;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .underline => |c| try std.fmt.format(writer, "\x1b[58;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .curly_underline => _ = try writer.write("\x1b[4:3m"),
        }
    }
};

pub const attributes = enum {
    pub const text = &[_]Attr{.{ .fg = color.white }};
    pub const selection = &[_]Attr{.{ .bg = color.gray3 }};
    pub const keyword = &[_]Attr{.{ .fg = color.magenta }};
    pub const string = &[_]Attr{.{ .fg = color.green }};
    pub const literal = &[_]Attr{.{ .fg = color.yellow }};
    pub const comment = &[_]Attr{.{ .fg = color.gray7 }};
    pub const diagnostic_error = &[_]Attr{ .curly_underline, .{ .underline = color.red } };
    pub const completion_menu = &[_]Attr{.{ .bg = color.gray2 }};
    pub const completion_menu_active = &[_]Attr{.{ .bg = color.gray4 }};
    pub const documentation_menu = &[_]Attr{.{ .bg = color.gray2 }};
    pub const message = &[_]Attr{.{ .bg = color.gray2 }};
    pub const number_line = &[_]Attr{.{ .fg = color.gray4 }};

    pub fn write(attrs: []const Attr, writer: anytype) !void {
        for (attrs) |attr| {
            try attr.write(writer);
        }
    }
};
