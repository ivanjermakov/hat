const std = @import("std");
const main = @import("main.zig");

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
    backspace,
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
    var key: Key = .{
        .printable = null,
        .code = null,
        .modifiers = 0,
    };
    const code = input.orderedRemove(0);
    switch (code) {
        0...31 => {
            // offset 96 converts \x1 to 'a', \x2 to 'b', and so on
            var buf = [1]u8{code + 96};
            // TODO: might not be printable
            key.printable = buf[0..];
            key.modifiers = @intFromEnum(Modifier.control);
        },
        32...126 => {
            var buf = [1]u8{code};
            key.printable = buf[0..];
        },
        0x7f => {
            key.code = KeyCode.backspace;
        },
        else => unreachable,
    }
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
