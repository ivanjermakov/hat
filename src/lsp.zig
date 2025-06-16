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

pub const LspConnection = struct {
    child: std.process.Child,
    messages_unreplied: std.AutoHashMap(i64, LspRequest),
};

var message_id: i64 = 0;
pub fn next_message_id() lsp.JsonRPCMessage.ID {
    message_id += 1;
    return .{ .number = message_id };
}

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
        .child = child,
        .messages_unreplied = std.AutoHashMap(i64, LspRequest).init(allocator),
    };
    try send_request(allocator, &conn, "initialize", .{ .capabilities = .{} });

    return conn;
}

fn send_request(
    allocator: std.mem.Allocator,
    conn: *LspConnection,
    comptime method: []const u8,
    params: lsp.types.getRequestMetadata(method).?.Params.?,
) !void {
    const request: lsp.TypedJsonRPCRequest(@TypeOf(params)) = .{
        .id = next_message_id(),
        .method = method,
        .params = params,
    };
    const json_message = try std.json.stringifyAlloc(allocator, request, .{});
    log.log(@This(), "> raw request: {s}\n", .{json_message});
    const rpc_message = try std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
    _ = try conn.child.stdin.?.write(rpc_message);
    defer allocator.free(rpc_message);
    try conn.messages_unreplied.put(request.id.number, .{ .method = method, .message = json_message });
}

fn send_notification(
    allocator: std.mem.Allocator,
    conn: *LspConnection,
    comptime method: []const u8,
    params: lsp.types.getNotificationMetadata(method).?.Params.?,
) !void {
    const request: lsp.TypedJsonRPCNotification(@TypeOf(params)) = .{
        .method = method,
        .params = params,
    };
    const json_message = try std.json.stringifyAlloc(allocator, request, .{});
    defer allocator.free(json_message);
    log.log(@This(), "> raw notification: {s}\n", .{json_message});
    const rpc_message = try std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
    _ = try conn.child.stdin.?.write(rpc_message);
    defer allocator.free(rpc_message);
}

pub fn update(allocator: std.mem.Allocator, conn: *LspConnection) !void {
    const raw_msgs = try poll(allocator, conn) orelse return;
    defer {
        for (raw_msgs) |msg| allocator.free(msg);
        allocator.free(raw_msgs);
    }
    for (raw_msgs) |raw_msg_json| {
        log.log(@This(), "< raw message: {s}\n", .{raw_msg_json});
        const msg_json = try std.json.parseFromSlice(lsp.JsonRPCMessage, allocator, raw_msg_json, .{});
        defer msg_json.deinit();
        const rpc_message: lsp.JsonRPCMessage = msg_json.value;
        switch (rpc_message) {
            .response => |resp| {
                const response_id = resp.id.?.number;
                const matched_request = conn.messages_unreplied.fetchRemove(response_id) orelse continue;
                defer allocator.free(matched_request.value.message);
                log.log(@This(), "response: {}\n", .{resp});

                if (std.mem.eql(u8, matched_request.value.method, "initialize")) {
                    const resp_typed = try std.json.parseFromValue(lsp.types.InitializeResult, allocator, resp.result_or_error.result.?, .{});
                    defer resp_typed.deinit();
                    log.log(@This(), "got init response\n", .{});
                    try send_notification(allocator, conn, "initialized", .{});

                    const buffer_uri = try std.fmt.allocPrint(allocator, "file://{s}", .{main.buffer.path});
                    defer allocator.free(buffer_uri);
                    try send_notification(allocator, conn, "textDocument/didOpen", .{
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

fn poll(allocator: std.mem.Allocator, conn: *const LspConnection) !?[][]u8 {
    if (main.log_enabled) b: {
        const err = fs.read_nonblock(allocator, conn.child.stderr.?) catch break :b;
        if (err) |e| {
            defer allocator.free(e);
            log.log(@This(), "err: {s}\n", .{e});
        }
    }

    const read = try fs.read_nonblock(allocator, conn.child.stdout.?) orelse return null;
    defer allocator.free(read);
    var read_stream = std.io.fixedBufferStream(read);
    const reader = read_stream.reader();

    var messages = std.ArrayList([]u8).init(allocator);
    while (true) {
        const header = lsp.BaseProtocolHeader.parse(reader) catch break;

        const json_message = try allocator.alloc(u8, header.content_length);
        errdefer allocator.free(json_message);
        _ = try reader.readAll(json_message);
        try messages.append(json_message);
    }

    return try messages.toOwnedSlice();
}
