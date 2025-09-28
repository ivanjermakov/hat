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
const ur = @import("uri.zig");

pub const lsp_config = [_]LspConfig{
    LspConfig{
        .name = "typescript-language-server",
        .cmd = &.{ "typescript-language-server", "--stdio" },
        .file_types = &.{ "typescript", "tsx" },
    },
    LspConfig{
        .name = "zls",
        .cmd = &.{ "zls", "--log-level", "debug" },
        .file_types = &.{"zig"},
        .settings =
        \\{
        \\    "enable_build_on_save": true,
        \\    "build_on_save_step": "check",
        \\    "enable_snippets": false,
        \\    "enable_argument_placeholders": false,
        \\    "warn_style": true
        \\}
        ,
    },
    LspConfig{
        .name = "cssls",
        .cmd = &.{ "vscode-css-language-server", "--stdio" },
        .file_types = &.{"css"},
        .settings =
        \\{
        \\    "css": {
        \\        "validate": true
        \\    }
        \\}
        ,
    },
    LspConfig{
        .name = "lua_ls",
        .cmd = &.{"lua-language-server"},
        .file_types = &.{"lua"},
    },
};

pub const LspConfig = struct {
    name: []const u8,
    cmd: []const []const u8,
    file_types: []const []const u8,
    settings: ?[]const u8 = null,
};

pub fn findLspsByFileType(allocator: Allocator, file_type: []const u8) ![]LspConfig {
    var res: std.array_list.Aligned(LspConfig, null) = .empty;
    for (lsp_config) |config| {
        for (config.file_types) |ft| {
            if (std.mem.eql(u8, file_type, ft)) {
                try res.append(allocator, config);
                break;
            }
        }
    }
    return try res.toOwnedSlice(allocator);
}

pub const LspRequest = struct {
    method: []const u8,
    message: []const u8,
};

pub const LspConnectionStatus = enum {
    created,
    initialized,
    disconnecting,
    closed,
};

pub const LspConnection = struct {
    config: LspConfig,
    status: LspConnectionStatus = .created,
    child: std.process.Child,
    messages_unreplied: std.AutoHashMap(i64, LspRequest),
    poll_buf: std.array_list.Aligned(u8, null) = .empty,
    poll_header: ?lsp.BaseProtocolHeader = null,
    buffers: std.array_list.Aligned(*buf.Buffer, null) = .empty,
    thread: std.Thread,
    client_capabilities: types.ClientCapabilities,
    server_init: ?std.json.Parsed(types.InitializeResult) = null,
    stdin_buf: [2 << 12]u8 = undefined,
    stdin_writer: std.fs.File.Writer,
    /// Updates left for connection to terminate until forced termination
    wait_fuel: usize = 30,
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
                        .snippetSupport = true,
                    },
                },
                .hover = .{
                    .contentFormat = &.{ .plaintext, .markdown },
                },
                .rename = .{
                    .prepareSupport = true,
                },
                .codeAction = .{
                    .codeActionLiteralSupport = .{
                        .codeActionKind = .{ .valueSet = &code_action_kinds },
                    },
                },
                .documentHighlight = .{},
                .formatting = .{},
            },
            .workspace = .{
                .workspaceFolders = true,
                .configuration = true,
                .didChangeConfiguration = .{},
                .executeCommand = .{},
            },
        };

        var self = LspConnection{
            .config = config,
            .child = child,
            .messages_unreplied = std.AutoHashMap(i64, LspRequest).init(allocator),
            .thread = undefined,
            .client_capabilities = client_capabilities,
            .stdin_writer = undefined,
            .allocator = allocator,
        };
        self.stdin_writer = child.stdin.?.writer(&self.stdin_buf);

        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        const workspace_uri = try ur.fromPath(allocator, cwd);
        defer allocator.free(workspace_uri);
        try self.sendRequest("initialize", types.InitializeParams{
            .capabilities = client_capabilities,
            .workspaceFolders = &.{.{ .uri = workspace_uri, .name = cwd }},
            .rootPath = cwd,
            .rootUri = workspace_uri,
        });

        return self;
    }

    pub fn lspLoop(self: *LspConnection) void {
        while (self.status != .closed and self.status != .disconnecting) {
            self.update() catch |e| log.err(@This(), "LSP update error: {}\n", .{e});
            std.Thread.sleep(main.sleep_lsp_ns);
        }
    }

    pub fn disconnect(self: *LspConnection) !void {
        try self.sendRequest("shutdown", null);
        try self.sendNotification("exit", null);
        self.status = .disconnecting;
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
                            const e = resp.result_or_error.@"error";
                            log.debug(@This(), "LSP error: {} {s}\n", .{ e.code, e.message });
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
                    log.trace(@This(), "< raw notification: {s}\n", .{raw_msg_json});
                    if (std.mem.eql(u8, notif.method, "window/logMessage")) {
                        const params_typed = try std.json.parseFromValue(types.LogMessageParams, arena.allocator(), notif.params.?, .{});
                        log.debug(@This(), "server log: {s}\n", .{params_typed.value.message});
                    } else if (std.mem.eql(u8, notif.method, "textDocument/publishDiagnostics")) {
                        try self.handlePublishDiagnosticsNotification(arena.allocator(), notif);
                    }
                },
                .request => |request| {
                    log.trace(@This(), "< raw request: {s}\n", .{raw_msg_json});
                    if (std.mem.eql(u8, request.method, "workspace/configuration")) {
                        try self.handleConfigurationRequest(arena.allocator(), request);
                    } else if (std.mem.eql(u8, request.method, "workspace/applyEdit")) {
                        try self.handleApplyEditRequest(arena.allocator(), request);
                    }
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
        self.buffers.deinit(self.allocator);
        if (self.server_init) |si| si.deinit();
        self.poll_buf.deinit(self.allocator);
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
        if ((self.server_init orelse return).value.capabilities.codeActionProvider == null) return;
        const buffer = main.editor.active_buffer;

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        defer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var diagnostics: std.array_list.Aligned(types.Diagnostic, null) = .empty;
        defer diagnostics.deinit(self.allocator);
        for (buffer.diagnostics.items) |diagnostic| {
            if (diagnostic.span.inRange(buffer.cursor)) {
                try diagnostics.append(self.allocator, try diagnostic.toLsp(arena.allocator()));
            }
        }

        try self.sendRequest("textDocument/codeAction", types.CodeActionParams{
            .textDocument = .{ .uri = buffer.uri },
            .range = (Span{ .start = buffer.cursor, .end = buffer.cursor }).toLsp(),
            .context = .{ .diagnostics = diagnostics.items },
        });
    }

    pub fn executeCommand(self: *LspConnection, command: types.Command) !void {
        log.trace(@This(), "command {}\n", .{command});
        try self.sendRequest("workspace/executeCommand", types.ExecuteCommandParams{
            .command = command.command,
            .arguments = command.arguments,
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
                .languageId = buffer.file_type.name,
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
            var changes = try std.array_list.Aligned(types.TextDocumentContentChangeEvent, null)
                .initCapacity(self.allocator, buffer.pending_changes.items.len);
            defer {
                for (changes.items) |change| self.allocator.free(change.literal_0.text);
                changes.deinit(self.allocator);
            }

            for (buffer.pending_changes.items) |change| {
                const event = try change.toLsp(self.allocator);
                try changes.append(self.allocator, event);
            }
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

    pub fn exitCode(self: *LspConnection) ?u8 {
        const term = std.posix.waitpid(self.child.id, std.posix.W.NOHANG);
        if (self.child.id == term.pid) return std.posix.W.EXITSTATUS(term.status);
        return null;
    }

    fn poll(self: *LspConnection) !?[]const []const u8 {
        if (self.status == .created or self.status == .initialized) {
            if (self.exitCode()) |code| {
                log.err(@This(), "lsp server terminated prematurely with code: {}\n", .{code});
                self.status = .closed;
                return error.ServerCrash;
            }
        }

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
        try self.poll_buf.appendSlice(self.allocator, read);

        var messages: std.array_list.Aligned([]const u8, null) = .empty;
        while (true) {
            if (self.poll_buf.items.len < lsp.BaseProtocolHeader.minimum_reader_buffer_size) break;
            var reader = std.io.Reader.fixed(try self.poll_buf.toOwnedSlice(self.allocator));
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
                try self.poll_buf.appendSlice(self.allocator, reader.buffer[reader.seek..]);
                break;
            }

            const json_message = try self.allocator.alloc(u8, header.content_length);
            errdefer self.allocator.free(json_message);
            _ = try reader.readSliceAll(json_message);
            try messages.append(self.allocator, json_message);

            // in case there is more messages in poll_buf, keep them
            try self.poll_buf.appendSlice(self.allocator, reader.buffer[reader.seek..]);
        }

        return try messages.toOwnedSlice(self.allocator);
    }

    fn sendRequest(
        self: *LspConnection,
        comptime method: []const u8,
        params: (types.getRequestMetadata(method).?.Params orelse ?void),
    ) !void {
        if (!std.mem.eql(u8, method, "initialize") and self.status != .initialized) {
            log.warn(@This(), "bad connection status: {}\n", .{self.status});
            return;
        }
        const request: lsp.TypedJsonRPCRequest(@TypeOf(params)) = .{
            .id = nextRequestId(),
            .method = method,
            .params = params,
        };
        const json_message = try std.json.Stringify.valueAlloc(self.allocator, request, default_stringify_opts);
        log.trace(@This(), "> raw request: {s}\n", .{json_message});
        try self.stdin_writer.interface.print("Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        try self.stdin_writer.interface.flush();

        try self.messages_unreplied.put(request.id.number, .{ .method = method, .message = json_message });
    }

    fn sendNotification(
        self: *LspConnection,
        comptime method: []const u8,
        params: (types.getNotificationMetadata(method).?.Params orelse ?void),
    ) !void {
        if (self.status != .initialized) {
            log.warn(@This(), "bad connection status: {}\n", .{self.status});
            return;
        }
        const request: lsp.TypedJsonRPCNotification(@TypeOf(params)) = .{
            .method = method,
            .params = params,
        };
        const json_message = try std.json.Stringify.valueAlloc(self.allocator, request, default_stringify_opts);
        defer self.allocator.free(json_message);
        log.trace(@This(), "> raw notification: {s}\n", .{json_message});
        try self.stdin_writer.interface.print("Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        try self.stdin_writer.interface.flush();
    }

    fn sendResponse(
        self: *LspConnection,
        comptime method: []const u8,
        id: lsp.JsonRPCMessage.ID,
        result: types.getRequestMetadata(method).?.Result,
    ) !void {
        if (self.status != .initialized) {
            log.warn(@This(), "bad connection status: {}\n", .{self.status});
            return;
        }
        const request: lsp.TypedJsonRPCResponse(@TypeOf(result)) = .{
            .id = id,
            .result_or_error = .{ .result = result },
        };
        const json_message = try std.json.Stringify.valueAlloc(self.allocator, request, default_stringify_opts);
        defer self.allocator.free(json_message);
        log.trace(@This(), "> raw response: {s}\n", .{json_message});
        try self.stdin_writer.interface.print("Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        try self.stdin_writer.interface.flush();
    }

    fn handleInitializeResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
        if (resp == null or resp.? == .null) return;
        self.server_init = try std.json.parseFromValue(types.InitializeResult, self.allocator, resp.?, .{});
        log.debug(@This(), "server capabilities: {f}\n", .{std.json.fmt(self.server_init.?.value.capabilities, .{})});

        self.status = .initialized;
        try self.sendNotification("initialized", .{});

        for (self.buffers.items) |buffer| {
            try self.didOpen(buffer);
        }

        if (self.config.settings) |settings| {
            const parsed = try std.json.parseFromSlice(std.json.Value, arena, settings, .{});
            try self.sendNotification("workspace/didChangeConfiguration", .{ .settings = parsed.value });
        }
    }

    fn handleDefinitionResponse(self: *LspConnection, arena: Allocator, resp: ?std.json.Value) !void {
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
                try main.editor.openBuffer(try self.allocator.dupe(u8, loc.uri));
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
            if (@errorReturnTrace()) |trace| log.errPrint("{f}\n", .{trace.*});
            return;
        };
        defer self.allocator.free(pick_result.path);
        log.debug(@This(), "picked reference: {}\n", .{pick_result});
        try main.editor.openBuffer(try ur.fromRelativePath(self.allocator, pick_result.path));
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

        main.main_loop_mutex.lock();
        defer main.main_loop_mutex.unlock();
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
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue([]const types.CodeAction, arena, resp.?, .{});
        const editor = &main.editor;

        editor.resetCodeActions();
        editor.code_actions = try act.fromLsp(self, result.value);
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
        if (resp == null or resp.? == .null) return;
        const result = try std.json.parseFromValue([]const types.DocumentHighlight, arena, resp.?, .{});
        const buffer = main.editor.active_buffer;
        buffer.highlights.clearRetainingCapacity();
        for (result.value) |hi| {
            try buffer.highlights.append(self.allocator, Span.fromLsp(hi.range));
        }
        if (buffer.highlights.items.len > 0) {
            log.debug(@This(), "got {} highlights\n", .{buffer.highlights.items.len});
            main.editor.dirty.draw = true;
        }
    }

    fn handlePublishDiagnosticsNotification(self: *LspConnection, arena: Allocator, notif: lsp.JsonRPCMessage.Notification) !void {
        const params_typed = try std.json.parseFromValue(types.PublishDiagnosticsParams, arena, notif.params.?, .{});
        if (main.editor.findBufferByUri(params_typed.value.uri)) |buffer| {
            buffer.clearDiagnostics();
            for (params_typed.value.diagnostics) |diagnostic| {
                try buffer.diagnostics.append(self.allocator, try dia.Diagnostic.fromLsp(buffer.allocator, diagnostic));
            }
            std.mem.sort(dia.Diagnostic, buffer.diagnostics.items, {}, dia.Diagnostic.lessThan);
            log.debug(@This(), "got {} diagnostics\n", .{buffer.diagnostics.items.len});
            if (buffer == main.editor.active_buffer) {
                main.editor.dirty.draw = true;
            }
        }
    }

    fn handleConfigurationRequest(self: *LspConnection, arena: Allocator, request: lsp.JsonRPCMessage.Request) !void {
        const params = (try std.json.parseFromValue(types.ConfigurationParams, arena, request.params.?, .{})).value;
        var response = try std.array_list.Managed(std.json.Value).initCapacity(arena, params.items.len);
        for (params.items) |_| {
            try response.append(std.json.Value.null);
        }
        try self.sendResponse("workspace/configuration", request.id, response.items);
    }

    fn handleApplyEditRequest(self: *LspConnection, arena: Allocator, request: lsp.JsonRPCMessage.Request) !void {
        _ = self;
        const params = (try std.json.parseFromValue(types.ApplyWorkspaceEditParams, arena, request.params.?, .{})).value;
        try main.editor.applyWorkspaceEdit(params.edit);
    }

    const default_stringify_opts = std.json.Stringify.Options{ .emit_null_optional_fields = false };
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

const code_action_kinds = [_]types.CodeActionKind{
    .empty,
    .quickfix,
    .refactor,
    .@"refactor.extract",
    .@"refactor.inline",
    .@"refactor.rewrite",
    .source,
    .@"source.organizeImports",
    .@"source.fixAll",
};
