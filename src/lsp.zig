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
    Created,
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
            .status = .Created,
            .child = child,
            .messages_unreplied = std.AutoHashMap(i64, LspRequest).init(allocator),
            .allocator = allocator,
        };
        try conn.send_request("initialize", .{ .capabilities = .{} });

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
        for (raw_msgs) |raw_msg_json| {
            log.log(@This(), "< raw message: {s}\n", .{raw_msg_json});
            const msg_json = try std.json.parseFromSlice(lsp.JsonRPCMessage, self.allocator, raw_msg_json, .{});
            defer msg_json.deinit();
            const rpc_message: lsp.JsonRPCMessage = msg_json.value;
            switch (rpc_message) {
                .response => |resp| {
                    const response_id = resp.id.?.number;
                    const matched_request = self.messages_unreplied.fetchRemove(response_id) orelse continue;
                    defer self.allocator.free(matched_request.value.message);
                    log.log(@This(), "response: {}\n", .{resp});

                    if (std.mem.eql(u8, matched_request.value.method, "initialize")) {
                        const resp_typed = try std.json.parseFromValue(lsp.types.InitializeResult, self.allocator, resp.result_or_error.result.?, .{});
                        defer resp_typed.deinit();
                        log.log(@This(), "got init response\n", .{});
                        try self.send_notification("initialized", .{});

                        const buffer_uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{main.buffer.path});
                        defer self.allocator.free(buffer_uri);
                        try self.send_notification("textDocument/didOpen", .{
                            .textDocument = .{
                                .uri = buffer_uri,
                                .languageId = "",
                                .version = 0,
                                .text = main.buffer.content_raw.items,
                            },
                        });
                    }
                },
                .notification => |notif| {
                    log.log(@This(), "notification: {s}\n", .{notif.method});
                },
                else => {},
            }
        }
    }

    fn poll(self: *LspConnection) !?[][]u8 {
        if (self.status == .Disconnecting) {
            const term = std.posix.waitpid(self.child.id, std.c.W.NOHANG);
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
