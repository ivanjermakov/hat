const std = @import("std");
const posix = std.posix;
const main = @import("main.zig");
const core = @import("core.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");
const buf = @import("buffer.zig");
const lsp = @import("lsp");

const Cursor = core.Cursor;
const Allocator = std.mem.Allocator;

const default_stringify_opts = std.json.StringifyOptions{ .emit_null_optional_fields = false };

pub const types = lsp.types;

pub const LspConfig = struct {
    name: []const u8,
    cmd: []const []const u8,
    file_types: []const []const u8,
};

pub const lsp_config = [_]LspConfig{
    LspConfig{
        .name = "typescript-language-server",
        .cmd = &.{ "typescript-language-server", "--stdio" },
        .file_types = &.{"typescript"},
    },
    LspConfig{
        .name = "zls",
        .cmd = &.{ "zls", "--log-level", "debug" },
        .file_types = &.{"zig"},
    },
};

pub fn findLspsByFileType(allocator: Allocator, file_type: []const u8) ![]LspConfig {
    var res = std.ArrayList(LspConfig).init(allocator);
    for (lsp_config) |config| {
        for (config.file_types) |ft| {
            if (std.mem.eql(u8, file_type, ft)) {
                try res.append(config);
                break;
            }
        }
    }
    return try res.toOwnedSlice();
}

pub const LspRequest = struct {
    method: []const u8,
    message: []const u8,
};

pub const LspConnectionStatus = enum {
    Created,
    Initialized,
    Disconnecting,
    Closed,
};

pub const LspConnection = struct {
    config: LspConfig,
    status: LspConnectionStatus,
    child: std.process.Child,
    messages_unreplied: std.AutoHashMap(i64, LspRequest),
    poll_buf: std.ArrayList(u8),
    poll_header: ?lsp.BaseProtocolHeader,
    buffers: std.ArrayList(*buf.Buffer),
    thread: std.Thread,
    allocator: Allocator,

    pub fn connect(allocator: Allocator, config: LspConfig) !LspConnection {
        var child = std.process.Child.init(config.cmd, allocator);
        // make child process resistant to terminal signals
        child.pgid = 0;
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();
        try child.waitForSpawn();

        var self = LspConnection{
            .config = config,
            .status = .Created,
            .child = child,
            .messages_unreplied = std.AutoHashMap(i64, LspRequest).init(allocator),
            .poll_buf = std.ArrayList(u8).init(allocator),
            .poll_header = null,
            .buffers = std.ArrayList(*buf.Buffer).init(allocator),
            .thread = undefined,
            .allocator = allocator,
        };

        try self.sendRequest("initialize", .{
            .capabilities = lsp.types.ClientCapabilities{
                .textDocument = .{
                    .definition = .{},
                    .diagnostic = .{},
                    .publishDiagnostics = .{},
                    .completion = .{
                        .completionItem = .{
                            .insertReplaceSupport = true,
                            .documentationFormat = &.{ .plaintext, .markdown },
                        },
                    },
                    .hover = .{
                        .contentFormat = &.{ .plaintext, .markdown },
                    },
                },
            },
        });

        return self;
    }

    pub fn lspLoop(self: *LspConnection) !void {
        while (self.status != .Closed) {
            try self.update();
            std.Thread.sleep(main.sleep_lsp_ns);
        }
    }

    pub fn disconnect(self: *LspConnection) !void {
        self.status = .Disconnecting;
        try self.sendRequest("shutdown", null);
        try self.sendNotification("exit", null);
    }

    pub fn update(self: *LspConnection) !void {
        const raw_msgs = try self.poll() orelse return;
        defer {
            for (raw_msgs) |msg| self.allocator.free(msg);
            self.allocator.free(raw_msgs);
        }

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        defer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        for (raw_msgs) |raw_msg_json| {
            const msg_json = try std.json.parseFromSlice(lsp.JsonRPCMessage, arena.allocator(), raw_msg_json, .{});
            defer msg_json.deinit();
            const rpc_message: lsp.JsonRPCMessage = msg_json.value;
            switch (rpc_message) {
                .response => |resp| {
                    // log.log(@This(), "< raw response: {s}\n", .{raw_msg_json});
                    const response_id = resp.id.?.number;

                    const response_result = b: switch (resp.result_or_error) {
                        .@"error" => {
                            log.log(@This(), "Lsp error: {}\n", .{resp.result_or_error.@"error"});
                            return;
                        },
                        .result => |r| break :b r,
                    };

                    const matched_request = self.messages_unreplied.fetchRemove(response_id) orelse continue;
                    defer self.allocator.free(matched_request.value.message);

                    const method = matched_request.value.method;
                    if (std.mem.eql(u8, method, "initialize")) {
                        try self.handleInitializeResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/definition")) {
                        try self.handleDefinitionResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
                        try self.handleCompletionResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
                        try self.handleHoverResponse(arena.allocator(), response_result);
                    }
                },
                .notification => |notif| {
                    try self.handleNotification(arena.allocator(), notif);
                },
                else => {},
            }
        }
    }

    pub fn deinit(self: *LspConnection) void {
        var iter = self.messages_unreplied.valueIterator();
        while (iter.next()) |value| {
            self.allocator.free(value.message);
        }
        self.messages_unreplied.deinit();
        self.buffers.deinit();
    }

    pub fn goToDefinition(self: *LspConnection) !void {
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/definition", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    pub fn hover(self: *LspConnection) !void {
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/hover", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    pub fn didOpen(self: *LspConnection, buffer: *buf.Buffer) !void {
        try self.sendNotification("textDocument/didOpen", .{
            .textDocument = .{
                .uri = buffer.uri,
                .languageId = "",
                .version = 0,
                .text = buffer.content_raw.items,
            },
        });
    }

    pub fn didClose(self: *LspConnection, buffer: *buf.Buffer) !void {
        try self.sendNotification("textDocument/didClose", .{
            .textDocument = .{ .uri = buffer.uri },
        });
    }

    pub fn didChange(self: *LspConnection, buffer: *buf.Buffer) !void {
        if (buffer.version == 0) {
            const changes = [_]lsp.types.TextDocumentContentChangeEvent{
                .{ .literal_1 = .{ .text = buffer.content_raw.items } },
            };
            try self.sendNotification("textDocument/didChange", .{
                .textDocument = .{ .uri = buffer.uri, .version = @intCast(buffer.version) },
                .contentChanges = &changes,
            });
        } else {
            var changes = try std.ArrayList(lsp.types.TextDocumentContentChangeEvent)
                .initCapacity(self.allocator, buffer.pending_changes.items.len);
            defer changes.deinit();
            for (buffer.pending_changes.items) |change| {
                const event = try change.toLsp(self.allocator);
                try changes.append(event);
            }
            defer for (changes.items) |event| {
                self.allocator.free(event.literal_0.text);
            };
            try self.sendNotification("textDocument/didChange", .{
                .textDocument = .{ .uri = buffer.uri, .version = @intCast(buffer.version) },
                .contentChanges = changes.items,
            });
        }
    }

    pub fn sendCompletionRequest(self: *LspConnection) !void {
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/completion", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    fn poll(self: *LspConnection) !?[]const []const u8 {
        if (main.log_enabled) b: {
            const err = fs.readNonblock(self.allocator, self.child.stderr.?) catch break :b;
            if (err) |e| {
                defer self.allocator.free(e);
                log.log(@This(), "err: {s}\n", .{e});
            }
        }

        const read = try fs.readNonblock(self.allocator, self.child.stdout.?) orelse return null;
        defer self.allocator.free(read);
        try self.poll_buf.appendSlice(read);

        var messages = std.ArrayList([]const u8).init(self.allocator);
        while (true) {
            if (self.poll_buf.items.len == 0) break;
            var read_stream = std.io.fixedBufferStream(self.poll_buf.items);
            const reader = read_stream.reader();

            const header = if (self.poll_header) |header| header else lsp.BaseProtocolHeader.parse(reader) catch |e| {
                log.log(@This(), "parse header error: {}\n", .{e});
                break;
            };
            const available: i32 = @as(i32, @intCast(self.poll_buf.items.len)) - @as(i32, @intCast(reader.context.pos));
            if (header.content_length <= available) {
                self.poll_header = null;
            } else {
                // if message is incomplete, save header for next `poll` call
                self.poll_header = header;
                const old = try self.poll_buf.toOwnedSlice();
                defer self.allocator.free(old);
                try self.poll_buf.appendSlice(old[reader.context.pos..]);
                break;
            }

            const json_message = try self.allocator.alloc(u8, header.content_length);
            errdefer self.allocator.free(json_message);
            _ = try reader.readAll(json_message);
            try messages.append(json_message);

            // in case there is more messages in poll_buf, keep them
            const old = try self.poll_buf.toOwnedSlice();
            defer self.allocator.free(old);
            try self.poll_buf.appendSlice(old[reader.context.pos..]);
        }

        return try messages.toOwnedSlice();
    }

    fn sendRequest(
        self: *LspConnection,
        comptime method: []const u8,
        params: (lsp.types.getRequestMetadata(method).?.Params orelse ?void),
    ) !void {
        const request: lsp.TypedJsonRPCRequest(@TypeOf(params)) = .{
            .id = nextRequestId(),
            .method = method,
            .params = params,
        };
        const json_message = try std.json.stringifyAlloc(self.allocator, request, default_stringify_opts);
        // log.log(@This(), "> raw request: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
        try self.messages_unreplied.put(request.id.number, .{ .method = method, .message = json_message });
    }

    fn sendNotification(
        self: *LspConnection,
        comptime method: []const u8,
        params: (lsp.types.getNotificationMetadata(method).?.Params orelse ?void),
    ) !void {
        const request: lsp.TypedJsonRPCNotification(@TypeOf(params)) = .{
            .method = method,
            .params = params,
        };
        const json_message = try std.json.stringifyAlloc(self.allocator, request, default_stringify_opts);
        defer self.allocator.free(json_message);
        // log.log(@This(), "> raw notification: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
    }

    fn handleInitializeResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        if (resp == null or resp.? == .null) return;
        const resp_typed = try std.json.parseFromValue(lsp.types.InitializeResult, arena, resp.?, .{});
        log.log(@This(), "got init response: {}\n", .{resp_typed});
        try self.sendNotification("initialized", .{});
        self.status = .Initialized;
        for (self.buffers.items) |buffer| {
            try self.didOpen(buffer);
        }
    }

    fn handleDefinitionResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const ResponseType = union(enum) {
            Definition: lsp.types.Definition,
            array_of_DefinitionLink: []const lsp.types.DefinitionLink,
        };
        const resp_typed = try lsp.parser.UnionParser(ResponseType).jsonParseFromValue(arena, resp.?, .{});
        log.log(@This(), "got definition response: {}\n", .{resp_typed});

        const location = b: switch (resp_typed.Definition) {
            .Location => |location| {
                break :b location;
            },
            .array_of_Location => |locations| {
                if (locations.len == 0) break :b null;
                if (locations.len > 1) log.log(@This(), "TODO: multiple locations\n", .{});
                break :b locations[0];
            },
        };
        if (location) |loc| {
            if (!std.mem.eql(u8, loc.uri, main.editor.active_buffer.uri)) {
                if (uriExtractPath(loc.uri)) |path| {
                    try main.editor.openBuffer(path);
                }
            }
            log.log(@This(), "jump to {}\n", .{loc.range.start});
            const new_cursor = Cursor.fromLsp(loc.range.start);
            try main.editor.active_buffer.moveCursor(new_cursor);
        }
    }

    fn handleCompletionResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const ResponseType = union(enum) {
            array_of_CompletionItem: []const lsp.types.CompletionItem,
            CompletionList: lsp.types.CompletionList,
        };

        const items: []const lsp.types.CompletionItem = b: {
            const empty = [_]lsp.types.CompletionItem{};
            const resp_typed = lsp.parser.UnionParser(ResponseType).jsonParseFromValue(arena, resp.?, .{}) catch break :b &empty;
            switch (resp_typed) {
                .array_of_CompletionItem => |a| break :b a,
                .CompletionList => |l| break :b l.items,
            }
        };
        main.editor.completion_menu.updateItems(items) catch |e| {
            log.log(@This(), "cmp menu update failed: {}\n", .{e});
        };
    }

    fn handleHoverResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue(lsp.types.Hover, arena, resp.?, .{});
        const contents = switch (result.value.contents) {
            .MarkupContent => |c| c.value,
            // deprecated
            .MarkedString, .array_of_MarkedString => return,
        };

        main.editor.resetHover();
        main.editor.hover_contents = try main.editor.allocator.dupe(u8, contents);
        log.log(@This(), "hover content: {s}\n", .{contents});
        main.editor.dirty.draw = true;
    }

    fn handleNotification(self: *LspConnection, arena: Allocator, notif: lsp.JsonRPCMessage.Notification) !void {
        _ = self;
        // log.log(@This(), "notification: {s}\n", .{notif.method});
        if (std.mem.eql(u8, notif.method, "window/logMessage")) {
            const params_typed = try std.json.parseFromValue(lsp.types.LogMessageParams, arena, notif.params.?, .{});
            log.log(@This(), "server log: {s}\n", .{params_typed.value.message});
        } else if (std.mem.eql(u8, notif.method, "textDocument/publishDiagnostics")) {
            const params_typed = try std.json.parseFromValue(lsp.types.PublishDiagnosticsParams, arena, notif.params.?, .{});
            log.log(@This(), "got {} diagnostics\n", .{params_typed.value.diagnostics.len});
            if (main.editor.findBufferByUri(params_typed.value.uri)) |target| {
                target.diagnostics.clearRetainingCapacity();
                try target.diagnostics.appendSlice(params_typed.value.diagnostics);
                if (target == main.editor.active_buffer) {
                    main.editor.dirty.draw = true;
                }
            }
        }
    }
};

var request_id: i64 = 0;
fn nextRequestId() lsp.JsonRPCMessage.ID {
    request_id += 1;
    return .{ .number = request_id };
}

pub fn extractTextEdit(item: lsp.types.CompletionItem) ?lsp.types.TextEdit {
    if (item.textEdit) |te| {
        switch (te) {
            .InsertReplaceEdit => |ire| return .{
                .range = ire.replace,
                .newText = ire.newText,
            },
            .TextEdit => |t| return t,
        }
    }
    return null;
}

pub fn uriExtractPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) {
        return uri[prefix.len..];
    }
    return null;
}
