const std = @import("std");
const main = @import("main.zig");

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
};

pub const Modifier = enum(u8) {
    shift = 1,
    alt = 2,
    control = 4,
    meta = 8,
};

pub const Key = struct {
    /// Printable UTF-8 string
    printable: ?[]u8,
    /// Non-printable key code
    code: ?KeyCode,
    /// Bit mask of Modifier enum
    modifiers: u4,
};

pub fn parse_ansi(input: *std.ArrayList(u8)) !Key {
    const code = input.orderedRemove(0);
    var buf = [1]u8{code};
    const key: Key = .{
        .printable = buf[0..],
        .code = null,
        .modifiers = 0,
    };
    if (main.log_enabled) {
        std.debug.print("{any}\n", .{key});
    }
    return key;
}

pub fn ansi_code_to_string(code: u8) ![]u8 {
    const is_printable = code >= 32 and code < 127;
    var buf: [1024]u8 = undefined;
    if (is_printable) {
        return std.fmt.bufPrint(&buf, "{c}", .{@as(u7, @intCast(code))});
    } else {
        return std.fmt.bufPrint(&buf, "\\x{x}", .{code});
    }
}
