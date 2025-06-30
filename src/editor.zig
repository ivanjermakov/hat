const std = @import("std");
const main = @import("main.zig");
const buf = @import("buffer.zig");
const cmp = @import("ui/completion_menu.zig");
const fzf = @import("ui/fzf.zig");
const log = @import("log.zig");

pub const Editor = struct {
    buffers: std.ArrayList(buf.Buffer),
    active_buffer: usize = 0,
    mode: Mode,
    needs_update_cursor: bool,
    needs_redraw: bool,
    needs_reparse: bool,
    needs_completion: bool,
    completion_menu: cmp.CompletionMenu,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        const editor = Editor{
            .buffers = std.ArrayList(buf.Buffer).init(allocator),
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

    pub fn openBuffer(self: *Editor, path: []const u8) !void {
        for (0..self.buffers.items.len) |buffer_idx| {
            const buffer = self.buffers.items[buffer_idx];
            // TODO: resolve paths
            if (std.mem.eql(u8, buffer.path, path)) {
                log.log(@This(), "opening existing buffer {s}\n", .{path});
                self.active_buffer = buffer_idx;
                return;
            }
        }
        log.log(@This(), "opening file at path {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        const file_content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_content);
        const buffer = try buf.Buffer.init(self.allocator, path, file_content);

        try self.buffers.append(buffer);
        self.active_buffer = self.buffers.items.len - 1;
        self.needs_reparse = true;
    }

    pub fn activeBuffer(self: *Editor) *buf.Buffer {
        return &self.buffers.items[self.active_buffer];
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |*buffer| buffer.deinit();
        self.buffers.deinit();
        self.completion_menu.deinit();
    }

    pub fn pickFile(self: *Editor) !void {
        const path = try fzf.pickFile(self.allocator);
        defer self.allocator.free(path);
        log.log(@This(), "picked path: {s}\n", .{path});
        try self.openBuffer(path);
    }

    pub fn findInFiles(self: *Editor) !void {
        const find_result = fzf.findInFiles(self.allocator) catch return;
        defer self.allocator.free(find_result.path);
        log.log(@This(), "find result: {}\n", .{find_result});
        try self.openBuffer(find_result.path);
        try self.activeBuffer().moveCursor(find_result.position);
    }
};

pub const Mode = enum {
    normal,
    select,
    select_line,
    insert,

    pub fn normalOrSelect(self: Mode) bool {
        return self == .normal or self == .select or self == .select_line;
    }
};
