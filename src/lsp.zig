const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;

const lsp = @import("lsp");
pub const types = lsp.types;

const buf = @import("buffer.zig");
const cha = @import("change.zig");
const core = @import("core.zig");
const Cursor = core.Cursor;
const Span = core.Span;
const fs = @import("fs.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const fzf = @import("ui/fzf.zig");
const dia = @import("ui/diagnostic.zig");
const act = @import("ui/code_action.zig");
const uri = @import("uri.zig");

const default_stringify_opts = std.json.Stringify.Options{ .emit_null_optional_fields = false };

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
    var res = std.array_list.Managed(LspConfig).init(allocator);
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
    poll_buf: std.array_list.Managed(u8),
    poll_header: ?lsp.BaseProtocolHeader,
    buffers: std.array_list.Managed(*buf.Buffer),
    thread: std.Thread,
    client_capabilities: types.ClientCapabilities,
    server_init: ?std.json.Parsed(types.InitializeResult) = null,
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

        const client_capabilities: types.ClientCapabilities = .{
            .textDocument = .{
                .definition = .{},
                .references = .{},
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
                .rename = .{
                    .prepareSupport = true,
                },
                .codeAction = .{},
                .formatting = .{},
                .documentHighlight = .{},
            },
            .workspace = .{
                .workspaceFolders = true,
            },
        };

        var self = LspConnection{
            .config = config,
            .status = .Created,
            .child = child,
            .messages_unreplied = std.AutoHashMap(i64, LspRequest).init(allocator),
            .poll_buf = std.array_list.Managed(u8).init(allocator),
            .poll_header = null,
            .buffers = std.array_list.Managed(*buf.Buffer).init(allocator),
            .thread = undefined,
            .client_capabilities = client_capabilities,
            .allocator = allocator,
        };

        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        const workspace_uri = try uri.fromPath(allocator, cwd);
        defer allocator.free(workspace_uri);
        try self.sendRequest("initialize", types.InitializeParams{
            .capabilities = client_capabilities,
            .workspaceFolders = &.{.{ .uri = workspace_uri, .name = cwd }},
            .rootPath = cwd,
            .rootUri = workspace_uri,
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
                    log.trace(@This(), "< raw response: {s}\n", .{raw_msg_json});
                    const response_id = resp.id.?.number;

                    const response_result = b: switch (resp.result_or_error) {
                        .@"error" => {
                            log.debug(@This(), "Lsp error: {}\n", .{resp.result_or_error.@"error"});
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
                    } else if (std.mem.eql(u8, method, "textDocument/references")) {
                        try self.handleFindReferencesResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
                        try self.handleCompletionResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
                        try self.handleHoverResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/rename")) {
                        try self.handleRenameResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
                        try self.handleCodeActionResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/formatting")) {
                        try self.handleFormattingResponse(arena.allocator(), response_result);
                    } else if (std.mem.eql(u8, method, "textDocument/documentHighlight")) {
                        try self.handleHighlightResponse(arena.allocator(), response_result);
                    }
                },
                .notification => |notif| {
                    try self.handleNotification(arena.allocator(), notif);
                },
                .request => {
                    log.trace(@This(), "< raw request: {s}\n", .{raw_msg_json});
                },
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
        if (self.server_init) |si| si.deinit();
        self.poll_buf.deinit();
    }

    pub fn goToDefinition(self: *LspConnection) !void {
        if ((self.server_init orelse return).value.capabilities.definitionProvider == null) return;
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/definition", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    pub fn findReferences(self: *LspConnection) !void {
        if ((self.server_init orelse return).value.capabilities.referencesProvider == null) return;
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/references", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
            .context = .{ .includeDeclaration = true },
        });
    }

    pub fn hover(self: *LspConnection) !void {
        if ((self.server_init orelse return).value.capabilities.hoverProvider == null) return;
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/hover", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    pub fn codeAction(self: *LspConnection) !void {
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/codeAction", .{
            .textDocument = .{ .uri = buffer.uri },
            .range = (Span{ .start = buffer.cursor, .end = buffer.cursor }).toLsp(),
            .context = .{ .diagnostics = &.{} },
        });
    }

    pub fn format(self: *LspConnection) !void {
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/formatting", .{
            .textDocument = .{ .uri = buffer.uri },
            .options = .{
                .tabSize = 4,
                .insertSpaces = true,
                .trimTrailingWhitespace = true,
            },
        });
    }

    pub fn highlight(self: *LspConnection) !void {
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/documentHighlight", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    pub fn rename(self: *LspConnection, new_name: []const u8) !void {
        if ((self.server_init orelse return).value.capabilities.renameProvider == null) return;
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/rename", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
            .newName = new_name,
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
            const changes = [_]types.TextDocumentContentChangeEvent{
                .{ .literal_1 = .{ .text = buffer.content_raw.items } },
            };
            try self.sendNotification("textDocument/didChange", .{
                .textDocument = .{ .uri = buffer.uri, .version = @intCast(buffer.version) },
                .contentChanges = &changes,
            });
        } else {
            var changes = try std.array_list.Managed(types.TextDocumentContentChangeEvent)
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
        if ((self.server_init orelse return).value.capabilities.completionProvider == null) return;
        const buffer = main.editor.active_buffer;
        try self.sendRequest("textDocument/completion", .{
            .textDocument = .{ .uri = buffer.uri },
            .position = buffer.cursor.toLsp(),
        });
    }

    fn poll(self: *LspConnection) !?[]const []const u8 {
        if (log.enabled(.@"error")) b: {
            var err_writer = std.io.Writer.Allocating.init(self.allocator);
            defer err_writer.deinit();
            fs.readNonblock(&err_writer.writer, self.child.stderr.?) catch break :b;
            const written = err_writer.written();
            if (written.len > 0) {
                log.err(@This(), "{s}\n", .{written});
            }
        }

        var out_writer = std.io.Writer.Allocating.init(self.allocator);
        defer out_writer.deinit();
        try fs.readNonblock(&out_writer.writer, self.child.stdout.?);
        const read = out_writer.written();
        if (read.len == 0) return null;
        try self.poll_buf.appendSlice(read);

        var messages = std.array_list.Managed([]const u8).init(self.allocator);
        while (true) {
            if (self.poll_buf.items.len < lsp.BaseProtocolHeader.minimum_reader_buffer_size) break;
            var reader = std.io.Reader.fixed(try self.poll_buf.toOwnedSlice());
            defer self.allocator.free(reader.buffer);

            const header = if (self.poll_header) |header| header else lsp.BaseProtocolHeader.parse(&reader) catch |e| {
                log.debug(@This(), "parse header error: {}\n", .{e});
                break;
            };
            const available: i32 = @as(i32, @intCast(reader.buffer.len)) - @as(i32, @intCast(reader.seek));
            if (header.content_length <= available) {
                self.poll_header = null;
            } else {
                // if message is incomplete, save header for next `poll` call
                self.poll_header = header;
                try self.poll_buf.appendSlice(reader.buffer[reader.seek..]);
                break;
            }

            const json_message = try self.allocator.alloc(u8, header.content_length);
            errdefer self.allocator.free(json_message);
            _ = try reader.readSliceAll(json_message);
            try messages.append(json_message);

            // in case there is more messages in poll_buf, keep them
            try self.poll_buf.appendSlice(reader.buffer[reader.seek..]);
        }

        return try messages.toOwnedSlice();
    }

    fn sendRequest(
        self: *LspConnection,
        comptime method: []const u8,
        params: (types.getRequestMetadata(method).?.Params orelse ?void),
    ) !void {
        const request: lsp.TypedJsonRPCRequest(@TypeOf(params)) = .{
            .id = nextRequestId(),
            .method = method,
            .params = params,
        };
        const json_message = try std.json.Stringify.valueAlloc(self.allocator, request, default_stringify_opts);
        log.trace(@This(), "> raw request: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
        try self.messages_unreplied.put(request.id.number, .{ .method = method, .message = json_message });
    }

    fn sendNotification(
        self: *LspConnection,
        comptime method: []const u8,
        params: (types.getNotificationMetadata(method).?.Params orelse ?void),
    ) !void {
        const request: lsp.TypedJsonRPCNotification(@TypeOf(params)) = .{
            .method = method,
            .params = params,
        };
        const json_message = try std.json.Stringify.valueAlloc(self.allocator, request, default_stringify_opts);
        defer self.allocator.free(json_message);
        log.trace(@This(), "> raw notification: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
    }

    fn sendResponse(
        self: *LspConnection,
        comptime method: []const u8,
        id: lsp.JsonRPCMessage.ID,
        result: types.getRequestMetadata(method).?.Result,
    ) !void {
        const request: lsp.TypedJsonRPCResponse(@TypeOf(result)) = .{
            .id = id,
            .result_or_error = .{ .result = result },
        };
        const json_message = try std.json.Stringify.valueAlloc(self.allocator, request, default_stringify_opts);
        defer self.allocator.free(json_message);
        log.trace(@This(), "> raw response: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
    }

    fn handleInitializeResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = arena;
        if (resp == null or resp.? == .null) return;
        self.server_init = try std.json.parseFromValue(types.InitializeResult, self.allocator, resp.?, .{});
        log.debug(@This(), "server capabilities: {f}\n", .{std.json.fmt(self.server_init.?.value.capabilities, .{})});
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
            Definition: types.Definition,
            array_of_DefinitionLink: []const types.DefinitionLink,
        };
        const resp_typed = try lsp.parser.UnionParser(ResponseType).jsonParseFromValue(arena, resp.?, .{});
        log.debug(@This(), "got definition response: {}\n", .{resp_typed});

        const location = b: switch (resp_typed.Definition) {
            .Location => |location| {
                break :b location;
            },
            .array_of_Location => |locations| {
                if (locations.len == 0) break :b null;
                // pick first location if multiple provided
                break :b locations[0];
            },
        };
        if (location) |loc| {
            if (!std.mem.eql(u8, loc.uri, main.editor.active_buffer.uri)) {
                if (uri.extractPath(loc.uri)) |path| {
                    try main.editor.openBuffer(path);
                }
            }
            log.debug(@This(), "jump to {}\n", .{loc.range.start});
            const new_cursor = Cursor.fromLsp(loc.range.start);
            main.editor.active_buffer.moveCursor(new_cursor);
        }
    }

    fn handleFindReferencesResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        if (resp == null or resp.? == .null) return;
        const resp_typed = try std.json.parseFromValue([]const types.Location, arena, resp.?, .{});
        const locations = resp_typed.value;
        log.debug(@This(), "got reference locations: {any}\n", .{locations});
        const pick_result = fzf.pickLspLocation(self.allocator, locations) catch |e| {
            log.err(@This(), "{}\n", .{e});
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
            return;
        };
        defer self.allocator.free(pick_result.path);
        log.debug(@This(), "picked reference: {}\n", .{pick_result});
        try main.editor.openBuffer(pick_result.path);
        main.editor.active_buffer.moveCursor(pick_result.position);
    }

    fn handleCompletionResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const ResponseType = union(enum) {
            array_of_CompletionItem: []const types.CompletionItem,
            CompletionList: types.CompletionList,
        };

        const items: []const types.CompletionItem = b: {
            const empty = [_]types.CompletionItem{};
            const resp_typed = lsp.parser.UnionParser(ResponseType).jsonParseFromValue(arena, resp.?, .{}) catch break :b &empty;
            switch (resp_typed) {
                .array_of_CompletionItem => |a| break :b a,
                .CompletionList => |l| break :b l.items,
            }
        };
        main.editor.completion_menu.updateItems(items) catch |e| {
            log.debug(@This(), "cmp menu update failed: {}\n", .{e});
        };
    }

    fn handleHoverResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue(types.Hover, arena, resp.?, .{});
        const contents = switch (result.value.contents) {
            .MarkupContent => |c| c.value,
            // deprecated
            .MarkedString, .array_of_MarkedString => return,
        };

        main.editor.resetHover();
        main.editor.hover_contents = try main.editor.allocator.dupe(u8, contents);
        log.debug(@This(), "hover content: {s}\n", .{contents});
        main.editor.dirty.draw = true;
    }

    fn handleRenameResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue(types.WorkspaceEdit, arena, resp.?, .{});
        main.main_loop_mutex.lock();
        defer main.main_loop_mutex.unlock();
        try main.editor.applyWorkspaceEdit(result.value);
    }

    fn handleCodeActionResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue([]const types.CodeAction, arena, resp.?, .{});
        const editor = &main.editor;

        editor.resetCodeActions();
        editor.code_actions = try act.fromLsp(editor.allocator, result.value);
        log.debug(@This(), "got {} code actions\n", .{editor.code_actions.?.len});
        editor.dirty.draw = true;
    }

    fn handleFormattingResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue([]const types.TextEdit, arena, resp.?, .{});
        log.debug(@This(), "got {} formatting edits\n", .{result.value.len});
        {
            main.main_loop_mutex.lock();
            defer main.main_loop_mutex.unlock();
            const buffer = main.editor.active_buffer;
            try buffer.applyTextEdits(result.value);
            try buffer.commitChanges();
        }
    }

    fn handleHighlightResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        _ = self;
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue([]const types.DocumentHighlight, arena, resp.?, .{});
        const buffer = main.editor.active_buffer;
        buffer.highlights.clearRetainingCapacity();
        for (result.value) |hi| {
            try buffer.highlights.append(Span.fromLsp(hi.range));
        }
        if (buffer.highlights.items.len > 0) {
            log.debug(@This(), "got {} highlights\n", .{buffer.highlights.items.len});
            main.editor.dirty.draw = true;
        }
    }

    fn handleNotification(self: *LspConnection, arena: Allocator, notif: lsp.JsonRPCMessage.Notification) !void {
        _ = self;
        log.trace(@This(), "notification: {s}\n", .{notif.method});
        if (std.mem.eql(u8, notif.method, "window/logMessage")) {
            const params_typed = try std.json.parseFromValue(types.LogMessageParams, arena, notif.params.?, .{});
            log.debug(@This(), "server log: {s}\n", .{params_typed.value.message});
        } else if (std.mem.eql(u8, notif.method, "textDocument/publishDiagnostics")) {
            const params_typed = try std.json.parseFromValue(types.PublishDiagnosticsParams, arena, notif.params.?, .{});
            log.debug(@This(), "got {} diagnostics\n", .{params_typed.value.diagnostics.len});
            if (main.editor.findBufferByUri(params_typed.value.uri)) |target| {
                target.clearDiagnostics();
                for (params_typed.value.diagnostics) |diagnostic| {
                    try target.diagnostics.append(try dia.Diagnostic.fromLsp(target.allocator, diagnostic));
                }
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

pub fn extractTextEdit(item: types.CompletionItem) ?types.TextEdit {
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
