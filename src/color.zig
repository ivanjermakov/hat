const std = @import("std");
const lsp = @import("lsp");

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

pub const color = struct {
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

pub const Attribute = union(enum) {
    fg: RgbColor,
    bg: RgbColor,
    underline: RgbColor,
    curly_underline,

    pub fn write(self: Attribute, writer: *std.io.Writer) !void {
        switch (self) {
            .fg => |c| try writer.print("\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .bg => |c| try writer.print("\x1b[48;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .underline => |c| try writer.print("\x1b[58;2;{};{};{}m", .{ c.r, c.g, c.b }),
            .curly_underline => _ = try writer.write("\x1b[4:3m"),
        }
    }
};

pub const attributes = enum {
    pub const text = &[_]Attribute{.{ .fg = color.white }};
    pub const selection = &[_]Attribute{.{ .bg = color.gray3 }};
    pub const selection_normal = &[_]Attribute{.{ .bg = color.gray2 }};
    pub const keyword = &[_]Attribute{.{ .fg = color.magenta }};
    pub const string = &[_]Attribute{.{ .fg = color.green }};
    pub const literal = &[_]Attribute{.{ .fg = color.yellow }};
    pub const comment = &[_]Attribute{.{ .fg = color.gray7 }};
    pub const completion_menu = &[_]Attribute{.{ .bg = color.gray2 }};
    pub const completion_menu_active = &[_]Attribute{.{ .bg = color.gray4 }};
    pub const overlay = &[_]Attribute{.{ .bg = color.gray2 }};
    pub const message = &[_]Attribute{.{ .bg = color.gray2 }};
    pub const command_line = &[_]Attribute{.{ .bg = color.gray2 }};
    pub const number_line = &[_]Attribute{.{ .fg = color.gray4 }};
    pub const diagnostic_error = &[_]Attribute{ .curly_underline, .{ .underline = color.red } };
    pub const diagnostic_warn = &[_]Attribute{ .curly_underline, .{ .underline = color.yellow } };
    pub const diagnostic_info = &[_]Attribute{ .curly_underline, .{ .underline = color.magenta } };
    pub const diagnostic_hint = &[_]Attribute{ .{ .fg = color.gray6 } };
    pub const highlight = &[_]Attribute{.{ .bg = color.gray3 }};

    pub fn writeSlice(attrs: []const Attribute, writer: *std.io.Writer) !void {
        for (attrs) |attr| {
            try attr.write(writer);
        }
    }

    pub fn diagnosticSeverity(severity: lsp.types.DiagnosticSeverity) []const Attribute {
        return switch (severity) {
            .Warning => diagnostic_warn,
            .Information => diagnostic_info,
            .Hint => diagnostic_hint,
            else => diagnostic_error,
        };
    }
};
