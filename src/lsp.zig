const std = @import("std");
const posix = std.posix;
const main = @import("main.zig");
const lsp = @import("lsp");

pub const LspConfig = struct {
    cmd: []const []const u8,
};

pub const LspConnection = struct { child: std.process.Child };

pub fn connect(config: *const LspConfig) !LspConnection {
    var child = std.process.Child.init(config.cmd, main.allocator);
    child.stdin_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    _ = try posix.fcntl(
        child.stdout.?.handle,
        posix.F.SETFL,
        try posix.fcntl(child.stdout.?.handle, posix.F.GETFL, 0) | posix.SOCK.NONBLOCK,
    );
    _ = try posix.fcntl(
        child.stderr.?.handle,
        posix.F.SETFL,
        try posix.fcntl(child.stderr.?.handle, posix.F.GETFL, 0) | posix.SOCK.NONBLOCK,
    );

    var transport: lsp.TransportOverStdio = .init(child.stdout.?, child.stdin.?);

    const request: lsp.TypedJsonRPCRequest(lsp.types.InitializeParams) = .{
        .id = .{ .number = 0 },
        .method = "initialize",
        .params = .{ .capabilities = .{} },
    };
    const json_message = try std.json.stringifyAlloc(main.allocator, request, .{ .emit_null_optional_fields = false });
    defer main.allocator.free(json_message);
    try transport.writeJsonMessage(json_message);

    return .{ .child = child };
}

pub fn poll(conn: *const LspConnection) !?[]u8 {
    b: {
        const err = read_nonblock(conn.child.stderr.?) catch break :b;
        if (err) |e| {
            std.debug.print("lsp err: {s}\n", .{e});
        }
    }

    return try read_nonblock(conn.child.stdout.?);
}

fn read_nonblock(file: std.fs.File) !?[]u8 {
    var res = std.ArrayList(u8).init(main.allocator);
    errdefer res.deinit();

    var b: [2048]u8 = undefined;
    while (true) {
        const read_len = file.read(&b) catch |e| {
            switch (e) {
                error.WouldBlock => break,
                else => return e,
            }
        };
        if (read_len == 0) break;
        try res.appendSlice(b[0..read_len]);
    }
    if (res.items.len == 0) {
        res.deinit();
        return null;
    }
    return try res.toOwnedSlice();
}
