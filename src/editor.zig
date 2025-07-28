const std = @import("std");
const main = @import("main.zig");
const buf = @import("buffer.zig");
const cmp = @import("ui/completion_menu.zig");
const cmd = @import("ui/command_line.zig");
const fzf = @import("ui/fzf.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const inp = @import("input.zig");
const uni = @import("unicode.zig");
const ter = @import("terminal.zig");

pub const Dirty = struct {
    input: bool = false,
    draw: bool = false,
    cursor: bool = false,
    completion: bool = false,
};

pub const DotRepeat = enum {
    outside,
    inside,
    commit_ready,
    executing,
};

pub const Editor = struct {
    /// List of buffers
    /// Must be always sorted recent-first
    buffers: std.ArrayList(*buf.Buffer),
    active_buffer: *buf.Buffer = undefined,
    mode: Mode,
    dirty: Dirty,
    completion_menu: cmp.CompletionMenu,
    command_line: cmd.CommandLine,
    lsp_connections: std.StringHashMap(lsp.LspConnection),
    messages: std.ArrayList([]const u8),
    message_read_idx: usize = 0,
    hover_contents: ?[]const u8 = null,
    key_queue: std.ArrayList(inp.Key),
    dot_repeat_input: std.ArrayList(inp.Key),
    dot_repeat_input_uncommitted: std.ArrayList(inp.Key),
    dot_repeat_state: DotRepeat = .outside,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        const editor = Editor{
            .buffers = std.ArrayList(*buf.Buffer).init(allocator),
            .mode = .normal,
            .dirty = .{},
            .completion_menu = cmp.CompletionMenu.init(allocator),
            .command_line = cmd.CommandLine.init(allocator),
            .lsp_connections = std.StringHashMap(lsp.LspConnection).init(allocator),
            .messages = std.ArrayList([]const u8).init(allocator),
            .key_queue = std.ArrayList(inp.Key).init(allocator),
            .dot_repeat_input = std.ArrayList(inp.Key).init(allocator),
            .dot_repeat_input_uncommitted = std.ArrayList(inp.Key).init(allocator),
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
            try conn.buffers.append(buffer);
            log.log(@This(), "attached buffer {s} to lsp {s}\n", .{ path, conn.config.name });
            if (conn.status == .Initialized) try conn.didOpen(buffer);
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

    pub fn findBufferByUri(self: *Editor, uri: []const u8) ?*buf.Buffer {
        for (self.buffers.items) |buffer| {
            if (std.mem.eql(u8, buffer.uri, uri)) {
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

    pub fn enterMode(self: *Editor, mode: Mode) !void {
        self.resetHover();

        if (self.mode == mode) return;
        if (self.mode == .insert) try self.active_buffer.commitChanges();

        switch (mode) {
            .normal => {
                try self.active_buffer.clearSelection();
                self.completion_menu.reset();
            },
            .select => try self.active_buffer.selectChar(),
            .select_line => try self.active_buffer.selectLine(),
            .insert => try self.active_buffer.clearSelection(),
        }
        if (mode != .normal) self.dotRepeatInside();
        log.log(@This(), "mode: {}->{}\n", .{ self.mode, mode });
        self.mode = mode;
        self.dirty.cursor = true;
    }

    pub fn deinit(self: *Editor) void {
        for (self.buffers.items) |buffer| {
            buffer.deinit();
            self.allocator.destroy(buffer);
        }
        self.buffers.deinit();

        self.completion_menu.deinit();
        self.command_line.deinit();

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

        for (self.key_queue.items) |key| if (key.printable) |p| self.allocator.free(p);
        self.key_queue.deinit();

        for (self.dot_repeat_input.items) |key| if (key.printable) |p| self.allocator.free(p);
        self.dot_repeat_input.deinit();

        for (self.dot_repeat_input_uncommitted.items) |key| if (key.printable) |p| self.allocator.free(p);
        self.dot_repeat_input_uncommitted.deinit();
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
        try self.updateInput();
    }

    pub fn updateInput(self: *Editor) !void {
        if (try ter.getCodes(self.allocator)) |codes| {
            defer self.allocator.free(codes);
            main.editor.dirty.input = true;
            const new_keys = try ter.getKeys(self.allocator, codes);
            defer self.allocator.free(new_keys);
            try main.editor.key_queue.appendSlice(new_keys);
        }
    }

    pub fn disconnect(self: *Editor) !void {
        while (self.lsp_connections.count() > 0) {
            var iter = self.lsp_connections.iterator();
            while (iter.next()) |entry| {
                const conn = entry.value_ptr;
                switch (conn.status) {
                    .Created, .Initialized => {
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
        self.message_read_idx = self.messages.items.len;
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

    pub fn writeInputString(self: *Editor, str: []const u8) !void {
        const keys = try ter.getKeys(self.allocator, str);
        defer self.allocator.free(keys);
        try self.key_queue.appendSlice(keys);
        self.dirty.input = true;
    }

    pub fn dotRepeatReset(self: *Editor) void {
        if (self.dot_repeat_state == .executing) return;
        self.dot_repeat_input_uncommitted.clearRetainingCapacity();
        self.dot_repeat_state = .outside;
    }

    pub fn dotRepeatStart(self: *Editor) void {
        if (self.dot_repeat_state == .executing) return;
        self.dot_repeat_input_uncommitted.clearRetainingCapacity();
        self.dot_repeat_state = .inside;
    }

    pub fn dotRepeatInside(self: *Editor) void {
        if (self.dot_repeat_state == .executing) return;
        self.dot_repeat_state = .inside;
    }

    pub fn dotRepeatOutside(self: *Editor) void {
        if (self.dot_repeat_state == .executing) return;
        self.dot_repeat_state = .outside;
    }

    pub fn dotRepeatExecuted(self: *Editor) void {
        if (self.dot_repeat_state == .executing) self.dot_repeat_state = .outside;
    }

    pub fn dotRepeatCommitReady(self: *Editor) !void {
        if (self.dot_repeat_state == .executing) return;
        self.dot_repeat_state = .commit_ready;
    }

    pub fn dotRepeatCommit(self: *Editor) !void {
        std.debug.assert(self.dot_repeat_state == .commit_ready);

        for (self.dot_repeat_input.items) |key| if (key.printable) |p| self.allocator.free(p);
        self.dot_repeat_input.clearRetainingCapacity();

        try self.dot_repeat_input.appendSlice(self.dot_repeat_input_uncommitted.items);
        self.dot_repeat_input_uncommitted.clearRetainingCapacity();
        self.dot_repeat_state = .outside;
    }

    pub fn dotRepeat(self: *Editor) !void {
        if (self.dot_repeat_input.items.len > 0) {
            log.log(@This(), "dot repeat of {any}\n", .{self.dot_repeat_input.items});
            for (self.dot_repeat_input.items) |key| {
                try self.key_queue.append(try key.clone(self.allocator));
            }
            self.dot_repeat_state = .executing;
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
