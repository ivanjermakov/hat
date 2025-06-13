const std = @import("std");
const main = @import("main.zig");

/// See section about "CSI Ps SP q" at
/// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Functions-using-CSI-_-ordered-by-the-final-character_s_
pub const cursor_type = .{
    .blinking_block = "\x1b[0 q",
    .blinking_block2 = "\x1b[1 q",
    .steady_block = "\x1b[2 q",
    .blinking_underline = "\x1b[3 q",
    .steady_underline = "\x1b[4 q",
    .blinking_bar = "\x1b[5 q",
    .steady_bar = "\x1b[6 q",
};

pub const KeyCode = enum {
    up,
    down,
    left,
    right,
    backspace,
    delete,
    enter,
    tab,
    escape,
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
    s: switch (code) {
        0x00...0x08, 0x10...0x19 => {
            // offset 96 converts \x1 to 'a', \x2 to 'b', and so on
            var buf = [1]u8{code + 96};
            // TODO: might not be printable
            key.printable = buf[0..];
            key.modifiers = @intFromEnum(Modifier.control);
        },
        0x09 => key.code = .tab,
        0x7f => key.code = .backspace,
        0x0d => key.code = .enter,
        0x1b => {
            if (input.items.len > 0 and input.items[0] == '[') {
                _ = input.orderedRemove(0);
                if (input.items.len > 0) {
                    switch (input.items[0]) {
                        'A' => {
                            _ = input.orderedRemove(0);
                            key.code = .up;
                            break :s;
                        },
                        'B' => {
                            _ = input.orderedRemove(0);
                            key.code = .down;
                            break :s;
                        },
                        'C' => {
                            _ = input.orderedRemove(0);
                            key.code = .right;
                            break :s;
                        },
                        'D' => {
                            _ = input.orderedRemove(0);
                            key.code = .left;
                            break :s;
                        },
                        '3' => {
                            _ = input.orderedRemove(0);
                            if (input.items.len > 0 and input.items[0] == '~') _ = input.orderedRemove(0);
                            key.code = .delete;
                            break :s;
                        },
                        else => return error.TodoCsi,
                    }
                }
            }
            key.code = .escape;
            break :s;
        },
        else => {
            var printable = std.ArrayList(u8).init(main.allocator);
            try printable.append(code);
            while (input.items.len > 0) {
                if (input.items[0] == 0x1b) break;
                const code2 = input.orderedRemove(0);
                try printable.append(code2);
            }
            key.printable = try printable.toOwnedSlice();
        },
    }
    if (main.log_enabled) {
        std.debug.print("{any}\n", .{key});
    }
    return key;
}

pub fn ansi_code_to_string(code: u8) ![]u8 {
    const is_printable = code >= 32 and code < 127;
    if (is_printable) {
        return std.fmt.allocPrint(main.allocator, "{c}", .{@as(u7, @intCast(code))});
    } else {
        return std.fmt.allocPrint(main.allocator, "\\x{x}", .{code});
    }
}
