const std = @import("std");
const main = @import("main.zig");
const buf = @import("buffer.zig");
const cmp = @import("ui/completion_menu.zig");

pub const Editor = struct {
    buffers: std.ArrayList(*buf.Buffer),
    active_buffer: ?*buf.Buffer,
    mode: Mode,
    needs_update_cursor: bool,
    needs_redraw: bool,
    needs_reparse: bool,
    needs_completion: bool,
    completion_menu: cmp.CompletionMenu,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        const editor = Editor{
            .buffers = std.ArrayList(*buf.Buffer).init(allocator),
            .active_buffer = null,
            .mode = .normal,
            .needs_update_cursor = false,
            .needs_redraw = false,
            .needs_reparse = false,
            .needs_completion = false,
            .completion_menu = cmp.CompletionMenu.init(allocator),
            .allocator = allocator,
        };
        return editor;
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |buffer| buffer.deinit();
        self.buffers.deinit();
        self.completion_menu.deinit();
    }
};

const Mode = enum {
    normal,
    select,
    insert,

    pub fn normalOrSelect(self: Mode) bool {
        return self == .normal or self == .select;
    }
};
