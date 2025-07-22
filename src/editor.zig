const std = @import("std");
const main = @import("main.zig");
const buf = @import("buffer.zig");
const cmp = @import("ui/completion_menu.zig");
const fzf = @import("ui/fzf.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const uni = @import("unicode.zig");

pub const Dirty = struct {
    draw: bool = false,
    cursor: bool = false,
    completion: bool = false,
};

pub const Editor = struct {
    /// List of buffers
    /// Must be always sorted recent-first
    buffers: std.ArrayList(*buf.Buffer),
    active_buffer: *buf.Buffer = undefined,
    mode: Mode,
    dirty: Dirty,
    completion_menu: cmp.CompletionMenu,
    lsp_connections: std.StringHashMap(lsp.LspConnection),
    messages: std.ArrayList([]const u8),
    message_read_idx: usize = 0,
    hover_contents: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        const editor = Editor{
            .buffers = std.ArrayList(*buf.Buffer).init(allocator),
            .mode = .normal,
            .dirty = .{},
            .completion_menu = cmp.CompletionMenu.init(allocator),
            .lsp_connections = std.StringHashMap(lsp.LspConnection).init(allocator),
            .messages = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
        return editor;
    }

    pub fn openBuffer(self: *Editor, path: []const u8) !void {
        if (self.findBufferByPath(path)) |existing| {
            log.log(@This(), "opening existing buffer {s}\n", .{path});
            // reinsert to maintain recent-first order
            const existing_idx = std.mem.indexOfScalar(*buf.Buffer, self.buffers.items, existing).?;
            _ = self.buffers.orderedRemove(existing_idx);
            try self.buffers.insert(0, existing);
            self.active_buffer = existing;
            main.editor.dirty.draw = true;
            return;
        }
        log.log(@This(), "opening file at path {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        const file_content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_content);
        var buffer = try self.allocator.create(buf.Buffer);
        buffer.* = try buf.Buffer.init(self.allocator, path, file_content);

        try self.buffers.insert(0, buffer);
        self.active_buffer = buffer;
        main.editor.dirty.draw = true;

        const lsp_configs = try lsp.findLspsByFileType(self.allocator, buffer.file_type.name);
        defer self.allocator.free(lsp_configs);
        for (lsp_configs) |lsp_conf| {
            const ftype = buffer.file_type.name;
            if (!self.lsp_connections.contains(ftype)) {
                const conn = try lsp.LspConnection.connect(self.allocator, lsp_conf);
                try self.lsp_connections.put(ftype, conn);
            }
            const conn = self.lsp_connections.getPtr(ftype).?;
            try buffer.lsp_connections.append(conn);
            log.log(@This(), "attached buffer {s} to lsp {s}\n", .{ path, conn.config.name });
            try conn.didChange(buffer);
        }
    }

    pub fn findBufferByPath(self: *Editor, path: []const u8) ?*buf.Buffer {
        for (self.buffers.items) |buffer| {
            // TODO: resolve paths
            if (std.mem.eql(u8, buffer.path, path)) {
                return buffer;
            }
        }
        return null;
    }

    pub fn openScratch(self: *Editor, content: ?[]const u8) !void {
        const buffer = try self.allocator.create(buf.Buffer);
        buffer.* = try buf.Buffer.init(self.allocator, null, content orelse "");
        log.log(@This(), "opening scratch {s}\n", .{buffer.path});

        try self.buffers.append(buffer);
        self.active_buffer = buffer;
        main.editor.dirty.draw = true;
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |buffer| {
            buffer.deinit();
            self.allocator.destroy(buffer);
        }
        self.buffers.deinit();

        self.completion_menu.deinit();

        {
            var val_iter = self.lsp_connections.valueIterator();
            while (val_iter.next()) |conn| conn.deinit();
        }
        self.lsp_connections.deinit();

        for (self.messages.items) |message| {
            self.allocator.free(message);
        }
        self.messages.deinit();

        self.resetHover();
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
        try self.active_buffer.moveCursor(find_result.position);
    }

    pub fn pickBuffer(self: *Editor) !void {
        const buf_path = fzf.pickBuffer(self.allocator, self.buffers.items) catch return;
        defer self.allocator.free(buf_path);
        log.log(@This(), "picked buffer: {s}\n", .{buf_path});
        try self.openBuffer(buf_path);
    }

    pub fn update(self: *Editor) !void {
        var lsp_iter = self.lsp_connections.valueIterator();
        while (lsp_iter.next()) |conn| try conn.update();
    }

    pub fn disconnect(self: *Editor) !void {
        while (self.lsp_connections.count() > 0) {
            var iter = self.lsp_connections.iterator();
            while (iter.next()) |entry| {
                const conn = entry.value_ptr;
                switch (conn.status) {
                    .Connected => {
                        log.log(@This(), "disconnecting lsp client\n", .{});
                        try conn.disconnect();
                    },
                    .Disconnecting => {
                        const term = std.posix.waitpid(conn.child.id, std.posix.W.NOHANG);
                        if (conn.child.id == term.pid) {
                            log.log(@This(), "lsp server terminated with code: {}\n", .{std.posix.W.EXITSTATUS(term.status)});
                            conn.status = .Closed;
                        }
                    },
                    .Closed => {
                        conn.deinit();
                        _ = self.lsp_connections.remove(entry.key_ptr.*);
                    },
                }
            }
            std.Thread.sleep(main.sleep_ns);
        }
    }

    pub fn sendMessage(self: *Editor, msg: []const u8) !void {
        log.log(@This(), "message: {s}\n", .{msg});
        try self.messages.append(try self.allocator.dupe(u8, msg));
        self.dirty.draw = true;
    }

    pub fn dismissMessage(self: *Editor) !void {
        if (self.message_read_idx == self.messages.items.len) return;
        self.message_read_idx += 1;
        self.dirty.draw = true;
    }

    pub fn closeBuffer(self: *Editor, force: bool) !void {
        const closing_buf = self.active_buffer;
        const allow_close_without_saving = force or closing_buf.scratch;
        if (!allow_close_without_saving and closing_buf.file_history_index != closing_buf.history_index) {
            try self.sendMessage("buffer has unsaved changes");
            return;
        }
        log.log(@This(), "closing buffer: {s}\n", .{closing_buf.path});
        defer self.allocator.destroy(closing_buf);
        defer closing_buf.deinit();
        std.debug.assert(closing_buf == self.buffers.items[0]);
        _ = self.buffers.orderedRemove(0);
        if (self.buffers.items.len == 0) return;
        try self.openBuffer(self.buffers.items[0].path);
    }

    pub fn resetHover(self: *Editor) void {
        if (self.hover_contents) |c| {
            self.hover_contents = null;
            self.allocator.free(c);
            main.editor.dirty.draw = true;
        }
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
