const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const buf = @import("buffer.zig");
const cha = @import("change.zig");
const core = @import("core.zig");
const FatalError = core.FatalError;
const inp = @import("input.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const main = @import("main.zig");
const ter = @import("terminal.zig");
const cmd = @import("ui/command_line.zig");
const cmp = @import("ui/completion_menu.zig");
const fzf = @import("ui/fzf.zig");
const uni = @import("unicode.zig");
const ur = @import("uri.zig");

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

pub const Config = struct {
    autosave: bool = false,
    /// Char to denote terminal lines after end of buffer
    /// See vim's :h fillchars -> eob
    end_of_buffer_char: ?u8 = null,
};

pub const Editor = struct {
    config: Config = .{},
    /// List of buffers
    /// Must be always sorted recent-first
    buffers: std.array_list.Managed(*buf.Buffer),
    active_buffer: *buf.Buffer = undefined,
    mode: Mode,
    dirty: Dirty,
    completion_menu: cmp.CompletionMenu,
    command_line: cmd.CommandLine,
    lsp_connections: std.StringHashMap(lsp.LspConnection),
    messages: std.array_list.Managed([]const u8),
    message_read_idx: usize = 0,
    hover_contents: ?[]const u8 = null,
    key_queue: std.array_list.Managed(inp.Key),
    dot_repeat_input: std.array_list.Managed(inp.Key),
    dot_repeat_input_uncommitted: std.array_list.Managed(inp.Key),
    dot_repeat_state: DotRepeat = .outside,
    find_query: ?[]const u21 = null,
    recording_macro: ?u8 = null,
    macros: std.AutoHashMap(u8, std.array_list.Managed(inp.Key)),
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: Config) !Editor {
        const editor = Editor{
            .config = config,
            .buffers = std.array_list.Managed(*buf.Buffer).init(allocator),
            .mode = .normal,
            .dirty = .{},
            .completion_menu = cmp.CompletionMenu.init(allocator),
            .command_line = cmd.CommandLine.init(allocator),
            .lsp_connections = std.StringHashMap(lsp.LspConnection).init(allocator),
            .messages = std.array_list.Managed([]const u8).init(allocator),
            .key_queue = std.array_list.Managed(inp.Key).init(allocator),
            .dot_repeat_input = std.array_list.Managed(inp.Key).init(allocator),
            .dot_repeat_input_uncommitted = std.array_list.Managed(inp.Key).init(allocator),
            .macros = std.AutoHashMap(u8, std.array_list.Managed(inp.Key)).init(allocator),
            .allocator = allocator,
        };
        return editor;
    }

    pub fn openBuffer(self: *Editor, path: []const u8) !void {
        if (self.buffers.items.len > 0 and std.mem.eql(u8, self.active_buffer.path, path)) return;
        defer self.resetHover();
        if (self.findBufferByPath(path)) |existing| {
            log.debug(@This(), "opening existing buffer {s}\n", .{path});
            // reinsert to maintain recent-first order
            const existing_idx = std.mem.indexOfScalar(*buf.Buffer, self.buffers.items, existing).?;
            _ = self.buffers.orderedRemove(existing_idx);
            try self.buffers.insert(0, existing);
            self.active_buffer = existing;
            main.editor.dirty.draw = true;
            return;
        }
        log.debug(@This(), "opening file at path {s}\n", .{path});
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
            conn.thread = try std.Thread.spawn(.{}, lsp.LspConnection.lspLoop, .{conn});

            try buffer.lsp_connections.append(conn);
            try conn.buffers.append(buffer);
            log.debug(@This(), "attached buffer {s} to lsp {s}\n", .{ path, conn.config.name });
            if (conn.status == .Initialized) try conn.didOpen(buffer);
        }
    }

    pub fn findBufferByPath(self: *Editor, path: []const u8) ?*buf.Buffer {
        for (self.buffers.items) |buffer| {
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
        defer self.resetHover();
        const buffer = try self.allocator.create(buf.Buffer);
        buffer.* = try buf.Buffer.init(self.allocator, null, content orelse "");
        log.debug(@This(), "opening scratch {s}\n", .{buffer.path});

        try self.buffers.insert(0, buffer);
        self.active_buffer = buffer;
        main.editor.dirty.draw = true;
    }

    pub fn enterMode(self: *Editor, mode: Mode) FatalError!void {
        self.resetHover();

        if (self.mode == mode) return;
        if (self.mode == .insert) try self.active_buffer.commitChanges();

        switch (mode) {
            .normal => {
                self.active_buffer.clearSelection();
                self.completion_menu.reset();
            },
            .select => self.active_buffer.selectChar(),
            .select_line => self.active_buffer.selectLine(),
            .insert => self.active_buffer.clearSelection(),
        }
        if (mode != .normal) self.dotRepeatInside();
        log.debug(@This(), "mode: {}->{}\n", .{ self.mode, mode });
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

        for (self.key_queue.items) |key| key.deinit();
        self.key_queue.deinit();

        for (self.dot_repeat_input.items) |key| key.deinit();
        self.dot_repeat_input.deinit();

        for (self.dot_repeat_input_uncommitted.items) |key| key.deinit();
        self.dot_repeat_input_uncommitted.deinit();

        if (self.find_query) |fq| self.allocator.free(fq);

        {
            var iter = self.macros.valueIterator();
            while (iter.next()) |keys| {
                for (keys.items) |key| key.deinit();
                keys.deinit();
            }
            self.macros.deinit();
        }
    }

    pub fn pickFile(self: *Editor) !void {
        const path = try fzf.pickFile(self.allocator);
        defer self.allocator.free(path);
        log.debug(@This(), "picked path: {s}\n", .{path});
        try self.openBuffer(path);
    }

    pub fn findInFiles(self: *Editor) !void {
        const find_result = fzf.findInFiles(self.allocator) catch return;
        defer self.allocator.free(find_result.path);
        log.debug(@This(), "find result: {}\n", .{find_result});
        try self.openBuffer(find_result.path);
        self.active_buffer.moveCursor(find_result.position);
    }

    pub fn pickBuffer(self: *Editor) !void {
        const buf_path = fzf.pickBuffer(self.allocator, self.buffers.items) catch return;
        defer self.allocator.free(buf_path);
        log.debug(@This(), "picked buffer: {s}\n", .{buf_path});
        try self.openBuffer(buf_path);
    }

    pub fn updateInput(self: *Editor) !void {
        if (try ter.getCodes(self.allocator, main.tty_in)) |codes| {
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
                        log.debug(@This(), "disconnecting lsp client\n", .{});
                        try conn.disconnect();
                    },
                    .Disconnecting => {
                        const term = std.posix.waitpid(conn.child.id, std.posix.W.NOHANG);
                        if (conn.child.id == term.pid) {
                            log.info(@This(), "lsp server terminated with code: {}\n", .{std.posix.W.EXITSTATUS(term.status)});
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

    pub fn startMacro(self: *Editor, name: u8) !void {
        if (self.recording_macro) |m| {
            try self.sendMessageFmt("already recording @{c}", .{m});
            return;
        }
        self.recording_macro = name;
        try self.sendMessageFmt("recording @{c}", .{name});
    }

    pub fn recordMacro(self: *Editor) !void {
        if (self.recording_macro) |name| {
            var macro = self.macros.getPtr(name).?;
            // drop first two keys since these mean "start recording"
            for (0..2) |_| {
                const rm = macro.orderedRemove(0);
                rm.deinit();
            }
            try self.sendMessageFmt("recorded @{c}", .{name});
            if (log.enabled(.debug)) {
                var keys_str = std.array_list.Managed(u8).init(self.allocator);
                defer keys_str.deinit();
                for (macro.items) |key| {
                    try keys_str.writer().print("{f}", .{key});
                }
                log.debug(@This(), "@{c}: \"{s}\"\n", .{ name, keys_str.items });
            }
            self.recording_macro = null;
        }
    }

    pub fn recordMacroKey(self: *Editor, key: inp.Key) !void {
        if (self.recording_macro) |name| {
            const gop = try self.macros.getOrPut(name);
            if (!gop.found_existing) gop.value_ptr.* = std.array_list.Managed(inp.Key).init(self.allocator);
            try gop.value_ptr.append(try key.clone(self.allocator));
        }
    }

    pub fn replayMacro(self: *Editor, name: u8) !void {
        if (self.recording_macro) |m| {
            // replaying macros while recording a macro is a tricky case, skip it
            log.warn(@This(), "attempt to replay macro @{c} while recording @{}\n", .{ name, m });
            return;
        }
        if (self.macros.get(name)) |macro| {
            log.debug(@This(), "replaying macro @{c}\n", .{name});
            for (macro.items) |key| {
                try self.key_queue.append(try key.clone(self.allocator));
            }
        } else {
            try self.sendMessageFmt("no macro @{c}", .{name});
        }
    }

    pub fn sendMessageFmt(self: *Editor, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(msg);
        try main.editor.sendMessage(msg);
    }

    pub fn sendMessage(self: *Editor, msg: []const u8) FatalError!void {
        log.debug(@This(), "message: {s}\n", .{msg});
        main.editor.dismissMessage();
        try self.messages.append(try self.allocator.dupe(u8, msg));
        self.dirty.draw = true;
    }

    pub fn dismissMessage(self: *Editor) void {
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
        log.debug(@This(), "closing buffer: {s}\n", .{closing_buf.path});
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

    pub fn writeInputString(self: *Editor, str: []const u8) FatalError!void {
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

    pub fn dotRepeatCommitReady(self: *Editor) void {
        if (self.dot_repeat_state == .executing) return;
        self.dot_repeat_state = .commit_ready;
    }

    pub fn dotRepeatCommit(self: *Editor) FatalError!void {
        std.debug.assert(self.dot_repeat_state == .commit_ready);

        for (self.dot_repeat_input.items) |key| key.deinit();
        self.dot_repeat_input.clearRetainingCapacity();

        try self.dot_repeat_input.appendSlice(self.dot_repeat_input_uncommitted.items);
        self.dot_repeat_input_uncommitted.clearRetainingCapacity();
        self.dot_repeat_state = .outside;
    }

    pub fn dotRepeat(self: *Editor) FatalError!void {
        if (self.dot_repeat_input.items.len > 0) {
            log.debug(@This(), "dot repeat of {any}\n", .{self.dot_repeat_input.items});
            for (self.dot_repeat_input.items) |key| {
                try self.key_queue.append(try key.clone(self.allocator));
            }
            self.dot_repeat_state = .executing;
        }
    }

    pub fn handleCmd(self: *Editor) !void {
        switch (self.command_line.command.?) {
            .find => {
                if (self.find_query) |fq| self.allocator.free(fq);
                self.find_query = try self.allocator.dupe(u21, self.command_line.content.items);
                try self.active_buffer.findNext(self.find_query.?, true);
            },
            .rename => {
                try self.active_buffer.rename(self.command_line.content.items);
            },
            .pipe => {
                try self.active_buffer.pipe(self.command_line.content.items);
                try self.enterMode(.normal);
            },
        }
        self.command_line.close();
    }

    pub fn applyWorkspaceEdit(self: *Editor, workspace_edit: lsp.types.WorkspaceEdit) !void {
        const old_buffer = self.active_buffer;
        const old_cursor = old_buffer.cursor;
        const old_offset = old_buffer.offset;
        log.debug(@This(), "workspace edit: {}\n", .{workspace_edit});
        var change_iter = workspace_edit.changes.?.map.iterator();
        while (change_iter.next()) |entry| {
            const change_uri = entry.key_ptr.*;
            const text_edits = entry.value_ptr.*;
            const path = try ur.toPath(self.allocator, change_uri);
            defer self.allocator.free(path);
            try self.openBuffer(path);
            const buffer = self.active_buffer;
            try buffer.applyTextEdits(text_edits);
            // TODO: apply another dummy edit that resets cursor position back to `old_cursor`
            // because now redoing rename jumps the cursor
            try buffer.commitChanges();
        }
        self.active_buffer = old_buffer;
        self.active_buffer.cursor = old_cursor;
        self.active_buffer.offset = old_offset;
        self.dirty.draw = true;
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
