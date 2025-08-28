const std = @import("std");
const Allocator = std.mem.Allocator;

const buf = @import("../buffer.zig");
const cha = @import("../change.zig");
const log = @import("../log.zig");
const lsp = @import("../lsp.zig");
const main = @import("../main.zig");
const uni = @import("../unicode.zig");

pub const Command = enum {
    find,
    rename,
    pipe,

    pub fn prefix(self: Command) []const u8 {
        return switch (self) {
            .find => "find: ",
            .rename => "rename: ",
            .pipe => "pipe: ",
        };
    }
};

pub const CommandLine = struct {
    content: std.array_list.Aligned(u21, null) = .empty,
    command: ?Command = null,
    cursor: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) CommandLine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandLine) void {
        self.content.deinit(self.allocator);
    }

    pub fn activate(self: *CommandLine, command: Command) void {
        self.command = command;
        log.debug(@This(), "active cmd: {}\n", .{command});
        main.editor.dirty.draw = true;
    }

    pub fn close(self: *CommandLine) void {
        self.command = null;
        self.content.clearRetainingCapacity();
        self.cursor = 0;
        main.editor.dirty.draw = true;
        log.debug(@This(), "cmd closed\n", .{});
    }

    pub fn insert(self: *CommandLine, text: []const u21) !void {
        std.debug.assert(self.command != null);
        try self.content.replaceRange(self.allocator, self.cursor, 0, text);
        self.cursor += text.len;
        main.editor.dirty.draw = true;
    }

    pub fn left(self: *CommandLine) void {
        if (self.cursor == 0) return;
        self.cursor -= 1;
        main.editor.dirty.draw = true;
    }

    pub fn right(self: *CommandLine) void {
        if (self.cursor == self.content.items.len) return;
        self.cursor += 1;
        main.editor.dirty.draw = true;
    }

    pub fn backspace(self: *CommandLine) void {
        if (self.cursor == 0) return;
        self.left();
        _ = self.content.orderedRemove(self.cursor);
        main.editor.dirty.draw = true;
    }

    pub fn delete(self: *CommandLine) void {
        if (self.cursor == self.content.items.len) return;
        _ = self.content.orderedRemove(self.cursor);
        main.editor.dirty.draw = true;
    }
};
