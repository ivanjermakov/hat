const std = @import("std");
const posix = std.posix;
const main = @import("main.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");
const lsp = @import("lsp");

pub const LspConfig = struct {
    cmd: []const []const u8,
};

pub const LspRequest = struct {
    method: []const u8,
    message: []const u8,
};

pub const LspConnectionStatus = enum {
    Connected,
    Disconnecting,
    Closed,
};

pub const LspConnection = struct {
    status: LspConnectionStatus,
    child: std.process.Child,
    messages_unreplied: std.AutoHashMap(i64, LspRequest),
    allocator: std.mem.Allocator,

    pub fn connect(allocator: std.mem.Allocator, config: *const LspConfig) !LspConnection {
        var child = std.process.Child.init(config.cmd, allocator);
        child.stdin_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();
        try child.waitForSpawn();

        fs.make_nonblock(child.stdout.?.handle);
        fs.make_nonblock(child.stderr.?.handle);

        var conn = LspConnection{
            .status = .Connected,
            .child = child,
            .messages_unreplied = std.AutoHashMap(i64, LspRequest).init(allocator),
            .allocator = allocator,
        };
        try conn.send_request("initialize", .{
            .capabilities = .{
                .textDocument = .{
                    .definition = .{},
                },
            },
        });

        return conn;
    }

    pub fn disconnect(self: *LspConnection) !void {
        self.status = .Disconnecting;
        try self.send_request("shutdown", null);
        try self.send_notification("exit", null);
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
            log.log(@This(), "< raw message: {s}\n", .{raw_msg_json});
            const msg_json = try std.json.parseFromSlice(lsp.JsonRPCMessage, arena.allocator(), raw_msg_json, .{});
            defer msg_json.deinit();
            const rpc_message: lsp.JsonRPCMessage = msg_json.value;
            switch (rpc_message) {
                .response => |resp| {
                    const response_id = resp.id.?.number;
                    const matched_request = self.messages_unreplied.fetchRemove(response_id) orelse continue;
                    defer self.allocator.free(matched_request.value.message);
                    log.log(@This(), "response: {}\n", .{resp});

                    if (std.mem.eql(u8, matched_request.value.method, "initialize")) {
                        const resp_typed = try std.json.parseFromValue(
                            lsp.types.InitializeResult,
                            arena.allocator(),
                            resp.result_or_error.result.?,
                            .{},
                        );
                        log.log(@This(), "got init response: {}\n", .{resp_typed});
                        try self.send_notification("initialized", .{});

                        try self.did_open();
                    } else if (std.mem.eql(u8, matched_request.value.method, "textDocument/definition")) {
                        const ResponseType = union(enum) {
                            Definition: lsp.types.Definition,
                            array_of_DefinitionLink: []const lsp.types.DefinitionLink,
                        };

                        const resp_typed = try lsp.parser.UnionParser(ResponseType).jsonParseFromValue(
                            arena.allocator(),
                            resp.result_or_error.result.?,
                            .{},
                        );
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
                            if (std.mem.eql(u8, loc.uri, main.buffer.uri)) {
                                log.log(@This(), "jump to {}\n", .{loc.range.start});
                                const new_cursor = main.buffer.inv_position(.{
                                    .line = loc.range.start.line,
                                    .character = loc.range.start.character,
                                });
                                main.buffer.move_cursor(new_cursor);
                            } else {
                                log.log(@This(), "TODO: jump to another file {s}\n", .{loc.uri});
                            }
                        }
                    }
                },
                .notification => |notif| {
                    log.log(@This(), "notification: {s}\n", .{notif.method});
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
    }

    pub fn go_to_definition(self: *LspConnection) !void {
        const position = main.buffer.position();
        try self.send_request("textDocument/definition", .{
            .textDocument = .{ .uri = main.buffer.uri },
            .position = .{
                .line = @intCast(position.line),
                .character = @intCast(position.character),
            },
        });
    }

    pub fn did_open(self: *LspConnection) !void {
        try self.send_notification("textDocument/didOpen", .{
            .textDocument = .{
                .uri = main.buffer.uri,
                .languageId = "",
                .version = 0,
                .text = main.buffer.content_raw.items,
            },
        });
    }

    pub fn did_change(self: *LspConnection) !void {
        const changes = [_]lsp.types.TextDocumentContentChangeEvent{
            .{ .literal_1 = .{ .text = main.buffer.content_raw.items } },
        };
        try self.send_notification("textDocument/didChange", .{
            .textDocument = .{ .uri = main.buffer.uri, .version = 0 },
            .contentChanges = &changes,
        });
    }

    fn poll(self: *LspConnection) !?[][]u8 {
        if (self.status == .Disconnecting) {
            const term = std.posix.waitpid(self.child.id, std.posix.W.NOHANG);
            if (self.child.id == term.pid) {
                log.log(@This(), "lsp server terminated with code: {}\n", .{std.posix.W.EXITSTATUS(term.status)});
                self.status = .Closed;
            }
        }

        if (main.log_enabled) b: {
            const err = fs.read_nonblock(self.allocator, self.child.stderr.?) catch break :b;
            if (err) |e| {
                defer self.allocator.free(e);
                log.log(@This(), "err: {s}\n", .{e});
            }
        }

        const read = try fs.read_nonblock(self.allocator, self.child.stdout.?) orelse return null;
        defer self.allocator.free(read);
        var read_stream = std.io.fixedBufferStream(read);
        const reader = read_stream.reader();

        var messages = std.ArrayList([]u8).init(self.allocator);
        while (true) {
            const header = lsp.BaseProtocolHeader.parse(reader) catch break;

            const json_message = try self.allocator.alloc(u8, header.content_length);
            errdefer self.allocator.free(json_message);
            _ = try reader.readAll(json_message);
            try messages.append(json_message);
        }

        return try messages.toOwnedSlice();
    }

    fn send_request(
        self: *LspConnection,
        comptime method: []const u8,
        params: (lsp.types.getRequestMetadata(method).?.Params orelse ?void),
    ) !void {
        const request: lsp.TypedJsonRPCRequest(@TypeOf(params)) = .{
            .id = next_message_id(),
            .method = method,
            .params = params,
        };
        const json_message = try std.json.stringifyAlloc(self.allocator, request, .{});
        log.log(@This(), "> raw request: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
        try self.messages_unreplied.put(request.id.number, .{ .method = method, .message = json_message });
    }

    fn send_notification(
        self: *LspConnection,
        comptime method: []const u8,
        params: (lsp.types.getNotificationMetadata(method).?.Params orelse ?void),
    ) !void {
        const request: lsp.TypedJsonRPCNotification(@TypeOf(params)) = .{
            .method = method,
            .params = params,
        };
        const json_message = try std.json.stringifyAlloc(self.allocator, request, .{});
        defer self.allocator.free(json_message);
        log.log(@This(), "> raw notification: {s}\n", .{json_message});
        const rpc_message = try std.fmt.allocPrint(self.allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
        _ = try self.child.stdin.?.write(rpc_message);
        defer self.allocator.free(rpc_message);
    }
};

var message_id: i64 = 0;
fn next_message_id() lsp.JsonRPCMessage.ID {
    message_id += 1;
    return .{ .number = message_id };
}
