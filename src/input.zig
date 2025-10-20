const std = @import("std");

const log = @import("log.zig");
const main = @import("main.zig");
const uni = @import("unicode.zig");

const Allocator = std.mem.Allocator;

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
    backspace,
    delete,
    escape,
    f1,
    f2,
    f3,
    f4,
    end,
    home,
    pgup,
    pgdown,
};

pub const Modifier = enum(u8) {
    shift = 1,
    alt = 2,
    control = 4,
    meta = 8,

    pub fn format(self: Modifier, writer: *std.io.Writer) std.io.Writer.Error!void {
        switch (self) {
            .shift => try writer.writeAll("s"),
            .alt => try writer.writeAll("m"),
            .control => try writer.writeAll("c"),
            .meta => try writer.writeAll("d"),
        }
    }
};

pub const Key = struct {
    /// Printable Unicode codepoint
    printable: ?u21 = null,
    /// Non-printable key code
    code: ?KeyCode = null,
    /// Bit mask of Modifier enum
    modifiers: u4 = 0,

    pub fn activeModifier(self: Key, modifier: Modifier) bool {
        return self.modifiers & @intFromEnum(modifier) > 0;
    }

    /// Following nvim convention for string representation of keystrokes:
    ///   * printable keys without modifiers printed as-is
    ///   * keys with modifiers or code-keys are printed in <> brackets
    ///   * code-keys print `KeyCode` name
    ///   * modifier list is dash separated
    ///   * everything is lowercase, except capitalized printable keys show as-is, without .shift modifier
    ///
    /// Modifier names and print order:
    ///   * m - alt
    ///   * c - control
    ///   * s - shift
    ///   * d - super/cmd
    ///
    /// Examples: a A ф 1 <c-a> <c-A> <left> <c-left> <m-c-s-d-left>
    pub fn format(self: *const Key, writer: *std.io.Writer) std.io.Writer.Error!void {
        const in_brackets = self.modifiers > 0 or self.code != null;
        if (in_brackets) try writer.writeAll("<");
        if (self.modifiers > 0) {
            for ([_]Modifier{ .alt, .control, .shift, .meta }) |m| {
                if (self.activeModifier(m)) try writer.print("{f}-", .{m});
            }
        }
        if (self.printable) |p| uni.unicodeToBytesWrite(writer, &.{p}) catch return error.WriteFailed;
        if (self.code) |code| try writer.print("{s}", .{@tagName(code)});
        if (in_brackets) try writer.writeAll(">");
    }
};

test "key format" {
    try expectKeyFormat(Key{}, "");
    try expectKeyFormat(Key{ .printable = 'a' }, "a");
    try expectKeyFormat(Key{ .printable = 'A' }, "A");
    try expectKeyFormat(Key{ .printable = 'ф' }, "ф");
    try expectKeyFormat(Key{ .printable = '1' }, "1");
    try expectKeyFormat(Key{ .printable = 'a', .modifiers = @intFromEnum(Modifier.control) }, "<c-a>");
    try expectKeyFormat(Key{ .printable = 'A', .modifiers = @intFromEnum(Modifier.control) }, "<c-A>");
    try expectKeyFormat(Key{ .code = .left }, "<left>");
    try expectKeyFormat(Key{ .code = .left, .modifiers = @intFromEnum(Modifier.control) }, "<c-left>");
    try expectKeyFormat(
        Key{
            .code = .left,
            .modifiers = @intFromEnum(Modifier.control) |
                @intFromEnum(Modifier.shift) |
                @intFromEnum(Modifier.alt) |
                @intFromEnum(Modifier.meta),
        },
        "<m-c-s-d-left>",
    );
}

fn expectKeyFormat(key: Key, expected: []const u8) !void {
    const allocator = std.testing.allocator;
    const actual = try std.fmt.allocPrint(allocator, "{f}", .{key});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
