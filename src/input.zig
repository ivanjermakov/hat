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

    pub fn clone(self: *const Key, allocator: std.mem.Allocator) !Key {
        var k = self.*;
        if (self.printable) |p| k.printable = try allocator.dupe(u8, p);
        return k;
    }
};

pub fn parse_ansi(allocator: std.mem.Allocator, input: *std.ArrayList(u8)) !Key {
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
            var printable = std.ArrayList(u8).init(allocator);
            defer printable.deinit();

            try printable.append(code);
            while (input.items.len > 0) {
                if (is_printable_ascii(input.items[0])) break;
                const code2 = input.orderedRemove(0);
                try printable.append(code2);
            }
            key.printable = try printable.toOwnedSlice();
        },
    }
    log.log(@This(), "{any}\n", .{key});
    return key;
}

pub fn get_codes(allocator: std.mem.Allocator) !?[]u8 {
    var in_buf = std.ArrayList(u8).init(allocator);
    while (true) {
        var b: [1]u8 = undefined;
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, b[0..1]) catch break;
        if (bytes_read == 0) break;
        try in_buf.appendSlice(b[0..]);
        // 1ns seems to be enough wait time for stdin to fill up with the next code
        std.Thread.sleep(1);
    }
    if (in_buf.items.len == 0) return null;

    if (main.log_enabled) {
        log.log(@This(), "input: ", .{});
        for (in_buf.items) |code| {
            const code_str = try ansi_code_to_string(allocator, code);
            defer allocator.free(code_str);
            std.debug.print("{s}", .{code_str});
        }
        std.debug.print("\n", .{});
    }

    return try in_buf.toOwnedSlice();
}

pub fn get_keys(allocator: std.mem.Allocator, codes: []u8) ![]Key {
    var keys = std.ArrayList(Key).init(allocator);

    var cs = std.ArrayList(u8).init(allocator);
    defer cs.deinit();
    try cs.appendSlice(codes);

    while (cs.items.len > 0) {
        const key = parse_ansi(allocator, &cs) catch |e| {
            log.log(@This(), "{}\n", .{e});
            continue;
        };
        try keys.append(key);
    }
    return try keys.toOwnedSlice();
}

fn ansi_code_to_string(allocator: std.mem.Allocator, code: u8) ![]u8 {
    const is_printable = code >= 32 and code < 127;
    if (is_printable) {
        return std.fmt.allocPrint(allocator, "{c}", .{@as(u7, @intCast(code))});
    } else {
        return std.fmt.allocPrint(allocator, "\\x{x}", .{code});
    }
}

fn is_printable_ascii(code: u8) bool {
    return code >= 0x21 and code <= 0x7e;
}
