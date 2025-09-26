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

    pub fn toHexStr(comptime self: RgbColor) []const u8 {
        return std.fmt.comptimePrint("{x}{x}{x}", .{ self.r, self.g, self.b });
    }
};

pub const AnsiColor = enum(u8) {
    black = 0,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,
    reset,

    pub fn format(self: AnsiColor, writer: *std.io.Writer) std.io.Writer.Error!void {
        if (self == .reset) {
            try writer.writeAll("\x1b[0m");
        } else {
            try writer.print("\x1b[38;5;{}m", .{@intFromEnum(self)});
        }
    }
};

pub const Color = struct {
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
    bold,

    pub fn write(self: Attr, writer: *std.io.Writer) !void {
        switch (self) {
            .fg => |c| try writer.print("\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .bg => |c| try writer.print("\x1b[48;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .underline => |c| try writer.print("\x1b[58;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .curly_underline => _ = try writer.write("\x1b[4:3m"),
            .bold => _ = try writer.write("\x1b[1m"),
        }
    }
};

pub const Attributes = struct {
    pub const text = &[_]Attr{.{ .fg = Color.white }};
    pub const selection = &[_]Attr{.{ .bg = Color.gray3 }};
    pub const selection_normal = &[_]Attr{.{ .bg = Color.gray2 }};
    pub const highlight = &[_]Attr{.{ .bg = Color.gray3 }};
    pub const keyword = &[_]Attr{.{ .fg = Color.magenta }};
    pub const string = &[_]Attr{.{ .fg = Color.green }};
    pub const literal = &[_]Attr{.{ .fg = Color.yellow }};
    pub const comment = &[_]Attr{.{ .fg = Color.gray7 }};
    pub const diagnostic_error = &[_]Attr{ .curly_underline, .{ .underline = Color.red } };
    pub const completion_menu = &[_]Attr{.{ .bg = Color.gray2 }};
    pub const completion_menu_active = &[_]Attr{.{ .bg = Color.gray4 }};
    pub const overlay = &[_]Attr{.{ .bg = Color.gray2 }};
    pub const message = &[_]Attr{.{ .bg = Color.gray2 }};
    pub const command_line = &[_]Attr{.{ .bg = Color.gray2 }};
    pub const number_line = &[_]Attr{.{ .fg = Color.gray4 }};
    pub const git_added = &[_]Attr{ .{ .fg = Color.green }, .bold };
    pub const git_modified = &[_]Attr{ .{ .fg = Color.yellow }, .bold };
    pub const git_deleted = &[_]Attr{ .{ .fg = Color.red }, .bold };

    pub fn write(attrs: []const Attr, writer: *std.io.Writer) !void {
        for (attrs) |attr| {
            try attr.write(writer);
        }
    }
};
