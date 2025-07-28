const std = @import("std");
const main = @import("../main.zig");
const lsp = @import("../lsp.zig");
const log = @import("../log.zig");
const buf = @import("../buffer.zig");
const uni = @import("../unicode.zig");
const cha = @import("../change.zig");

pub const Command = enum {
    find,

    pub fn prefix(self: Command) []const u8 {
        return switch (self) {
            .find => "find: ",
        };
    }
};

pub const CommandLine = struct {
    content: std.ArrayList(u21),
    command: ?Command = null,
    cursor: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CommandLine {
        return .{
            .content = std.ArrayList(u21).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CommandLine) void {
        self.content.deinit();
    }

    pub fn activate(self: *CommandLine, command: Command) !void {
        self.command = command;
        log.log(@This(), "active cmd: {}\n", .{command});
        main.editor.dirty.draw = true;
    }

    pub fn close(self: *CommandLine) void {
        self.command = null;
        self.content.clearRetainingCapacity();
        self.cursor = 0;
        main.editor.dirty.draw = true;
    }

    pub fn insert(self: *CommandLine, text: []const u21) !void {
        std.debug.assert(self.command != null);
        try self.content.replaceRange(self.cursor, 0, text);
        self.cursor += text.len;
        main.editor.dirty.draw = true;
    }
};
