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
};

pub const Key = struct {
    /// Printable UTF-8 string
    printable: ?[]u8 = null,
    /// Non-printable key code
    code: ?KeyCode = null,
    /// Bit mask of Modifier enum
    modifiers: u4 = 0,

    pub fn clone(self: *const Key, allocator: std.mem.Allocator) !Key {
        var k = self.*;
        if (self.printable) |p| k.printable = try allocator.dupe(u8, p);
        return k;
    }
};
