const std = @import("std");
const posix = std.posix;
const main = @import("main.zig");
const fs = @import("fs.zig");
const lsp = @import("lsp");

pub const LspConfig = struct {
    cmd: []const []const u8,
};

pub const LspConnection = struct {
    child: std.process.Child,
    messages_unreplied: std.AutoHashMap(lsp.JsonRPCMessage.ID, lsp.JsonRPCMessage),
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

    const conn = LspConnection{
        .child = child,
        .messages_unreplied = std.AutoHashMap(lsp.JsonRPCMessage.ID, lsp.JsonRPCMessage).init(allocator),
    };

    const request: lsp.TypedJsonRPCRequest(lsp.types.InitializeParams) = .{
        .id = next_message_id(),
        .method = "initialize",
        .params = .{ .capabilities = .{} },
    };
    const json_message = try std.json.stringifyAlloc(allocator, request, .{ .emit_null_optional_fields = false });
    defer allocator.free(json_message);
    const rpc_message = try std.fmt.allocPrint(allocator, "Content-Length: {}\r\n\r\n{s}", .{ json_message.len, json_message });
    _ = try conn.child.stdin.?.write(rpc_message);

    return conn;
}

pub fn poll(allocator: std.mem.Allocator, conn: *const LspConnection) !?[]u8 {
    if (main.log_enabled) b: {
        const err = fs.read_nonblock(allocator, conn.child.stderr.?) catch break :b;
        if (err) |e| {
            std.debug.print("lsp err: {s}\n", .{e});
        }
    }

    return try fs.read_nonblock(main.allocator, conn.child.stdout.?);
}
