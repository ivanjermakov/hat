const std = @import("std");
const main = @import("main.zig");
const buf = @import("buffer.zig");
const cmp = @import("ui/completion_menu.zig");
const fzf = @import("ui/fzf.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");

pub const Dirty = struct {
    draw: bool = false,
    cursor: bool = false,
    completion: bool = false,
};

pub const Editor = struct {
    buffers: std.ArrayList(*buf.Buffer),
    active_buffer: *buf.Buffer = undefined,
    mode: Mode,
    dirty: Dirty,
    completion_menu: cmp.CompletionMenu,
    lsp_connections: std.StringHashMap(lsp.LspConnection),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Editor {
        const editor = Editor{
            .buffers = std.ArrayList(*buf.Buffer).init(allocator),
            .mode = .normal,
            .dirty = .{},
            .completion_menu = cmp.CompletionMenu.init(allocator),
            .lsp_connections = std.StringHashMap(lsp.LspConnection).init(allocator),
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
                self.active_buffer = buffer;
                return;
            }
        }
        log.log(@This(), "opening file at path {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        const file_content = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(file_content);
        var buffer = try self.allocator.create(buf.Buffer);
        buffer.* = try buf.Buffer.init(self.allocator, path, file_content);

        try self.buffers.append(buffer);
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
