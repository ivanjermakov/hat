const std = @import("std");
const main = @import("main.zig");
const log = @import("log.zig");

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
    backspace,
    delete,
    tab,
    escape,
};

pub const Modifier = enum(u8) {
    shift = 1,
    alt = 2,
    control = 4,
    meta = 8,

    pub fn format(
        self: Modifier,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        switch (self) {
            .shift => try writer.writeAll("s"),
            .alt => try writer.writeAll("m"),
            .control => try writer.writeAll("c"),
            .meta => try writer.writeAll("d"),
        }
    }
};

pub const Key = struct {
    /// Printable UTF-8 string
    printable: ?[]const u8 = null,
    /// Non-printable key code
    code: ?KeyCode = null,
    /// Bit mask of Modifier enum
    modifiers: u4 = 0,

    pub fn clone(self: *const Key, allocator: std.mem.Allocator) !Key {
        var k = self.*;
        if (self.printable) |p| k.printable = try allocator.dupe(u8, p);
        return k;
    }

    pub fn activeModifier(self: *const Key, modifier: Modifier) bool {
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
    pub fn format(
        self: *const Key,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const in_brackets = self.modifiers > 0 or self.code != null;
        if (in_brackets) try writer.writeAll("<");
        if (self.modifiers > 0) {
            for ([_]Modifier{ .alt, .control, .shift, .meta }) |m| {
                if (self.activeModifier(m)) try std.fmt.format(writer, "{}-", .{m});
            }
        }
        if (self.printable) |printable| try std.fmt.format(writer, "{s}", .{printable});
        if (self.code) |code| try std.fmt.format(writer, "{s}", .{@tagName(code)});
        if (in_brackets) try writer.writeAll(">");
    }

    fn expectKeyFormat(key: Key, expected: []const u8) !void {
        const allocator = std.testing.allocator;
        const actual = try std.fmt.allocPrint(allocator, "{}", .{key});
        defer allocator.free(actual);
        try std.testing.expectEqualStrings(actual, expected);
    }

    test "key format" {
        try expectKeyFormat(Key{}, "");
        try expectKeyFormat(Key{ .printable = "a" }, "a");
        try expectKeyFormat(Key{ .printable = "A" }, "A");
        try expectKeyFormat(Key{ .printable = "ф" }, "ф");
        try expectKeyFormat(Key{ .printable = "1" }, "1");
        try expectKeyFormat(Key{ .printable = "a", .modifiers = @intFromEnum(Modifier.control) }, "<c-a>");
        try expectKeyFormat(Key{ .printable = "A", .modifiers = @intFromEnum(Modifier.control) }, "<c-A>");
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
};
