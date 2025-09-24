const std = @import("std");
const Allocator = std.mem.Allocator;

const lsp = @import("../lsp.zig");
const log = @import("../log.zig");

pub const hint_bag: []const u8 = &.{ 'f', 'j', 'd', 'k', 's', 'l', 'a', 'b', 'c', 'e', 'g', 'h', 'i', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z' };

pub const CodeAction = struct {
    connection: *lsp.LspConnection,
    hint: u8,
    title: []const u8,
    /// Stringified `lsp.types.WorkspaceEdit`
    edit_json: ?[]const u8,
    /// Stringified `lsp.types.Command`
    command_json: ?[]const u8,
    allocator: Allocator,

    pub fn init(connection: *lsp.LspConnection, code_action: lsp.types.CodeAction) !CodeAction {
        const allocator = connection.allocator;
        log.trace(@This(), "raw code action: {}\n", .{code_action});
        if (code_action.command) |c| {
            log.trace(@This(), "command: {s}\n", .{c.title});
        }
        const title = try allocator.dupe(u8, code_action.title);
        return .{
            .connection = connection,
            .hint = title[0],
            .title = title,
            .edit_json = if (code_action.edit) |e| try std.json.Stringify.valueAlloc(allocator, e, .{}) else null,
            .command_json = if (code_action.command) |c| try std.json.Stringify.valueAlloc(allocator, c, .{}) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const CodeAction) void {
        self.allocator.free(self.title);
        if (self.edit_json) |e| self.allocator.free(e);
        if (self.command_json) |c| self.allocator.free(c);
    }
};

pub fn fromLsp(connection: *lsp.LspConnection, lsp_code_actions: []const lsp.types.CodeAction) ![]const CodeAction {
    const allocator = connection.allocator;
    var bag: std.array_list.Aligned(u8, null) = .empty;
    try bag.appendSlice(allocator, hint_bag);
    defer bag.deinit(allocator);
    var code_actions = std.array_list.Managed(CodeAction).init(allocator);
    for (lsp_code_actions) |lsp_code_action| {
        var action = try CodeAction.init(connection, lsp_code_action);
        if (std.mem.indexOfScalar(u8, bag.items, action.hint)) |available_idx| {
            _ = bag.orderedRemove(available_idx);
        } else {
            action.hint = bag.orderedRemove(0);
        }
        try code_actions.append(action);
    }
    return try code_actions.toOwnedSlice();
}

test "fromLsp with collisions" {
    const allocator = std.testing.allocator;
    var connection = lsp.LspConnection{
        .config = undefined,
        .child = undefined,
        .messages_unreplied = undefined,
        .thread = undefined,
        .client_capabilities = undefined,
        .stdin_writer = undefined,
        .allocator = allocator,
    };

    const result = try fromLsp(&connection, &.{
        .{ .title = "foo", .edit = .{} },
        .{ .title = "bar", .edit = .{} },
        .{ .title = "baz", .edit = .{} },
        .{ .title = "doo", .edit = .{} },
        .{ .title = "bax", .edit = .{} },
    });
    defer {
        for (result) |a| a.deinit();
        allocator.free(result);
    }

    try std.testing.expectEqual('f', result[0].hint);
    try std.testing.expectEqual('b', result[1].hint);
    try std.testing.expectEqual('j', result[2].hint);
    try std.testing.expectEqual('d', result[3].hint);
    try std.testing.expectEqual('k', result[4].hint);
}
