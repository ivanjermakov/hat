const std = @import("std");

const log = @import("log.zig");
const main = @import("main.zig");

const Allocator = std.mem.Allocator;

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
    backspace,
    delete,
    tab,
    escape,
    f1,
    f2,
    f3,
    f4,
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
    allocator: Allocator,

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

    pub fn deinit(self: *const Key) void {
        if (self.printable) |p| self.allocator.free(p);
    }
};

test "key format" {
    const a = std.testing.allocator;
    try expectKeyFormat(Key{ .allocator = a }, "");
    try expectKeyFormat(Key{ .allocator = a, .printable = "a" }, "a");
    try expectKeyFormat(Key{ .allocator = a, .printable = "A" }, "A");
    try expectKeyFormat(Key{ .allocator = a, .printable = "ф" }, "ф");
    try expectKeyFormat(Key{ .allocator = a, .printable = "1" }, "1");
    try expectKeyFormat(Key{ .allocator = a, .printable = "a", .modifiers = @intFromEnum(Modifier.control) }, "<c-a>");
    try expectKeyFormat(Key{ .allocator = a, .printable = "A", .modifiers = @intFromEnum(Modifier.control) }, "<c-A>");
    try expectKeyFormat(Key{ .allocator = a, .code = .left }, "<left>");
    try expectKeyFormat(Key{ .allocator = a, .code = .left, .modifiers = @intFromEnum(Modifier.control) }, "<c-left>");
    try expectKeyFormat(
        Key{
            .allocator = a,
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
    const actual = try std.fmt.allocPrint(allocator, "{}", .{key});
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}
