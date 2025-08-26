const std = @import("std");
const Allocator = std.mem.Allocator;

const lsp = @import("../lsp.zig");

pub const hint_bag: []const u8 = &.{ 'f', 'j', 'd', 'k', 's', 'l', 'a', 'b', 'c', 'e', 'g', 'h', 'i', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z' };

pub const CodeAction = struct {
    hint: u8,
    title: []const u8,
    /// Stringified `lsp.types.WorkspaceEdit`
    edit_json: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, code_action: lsp.types.CodeAction) !CodeAction {
        const title = try allocator.dupe(u8, code_action.title);
        return .{
            .hint = title[0],
            .title = title,
            .edit_json = try std.json.Stringify.valueAlloc(allocator, code_action.edit.?, .{}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const CodeAction) void {
        self.allocator.free(self.title);
        self.allocator.free(self.edit_json);
    }
};

pub fn fromLsp(allocator: Allocator, lsp_code_actions: []const lsp.types.CodeAction) ![]const CodeAction {
    var bag = std.array_list.Managed(u8).init(allocator);
    try bag.appendSlice(hint_bag);
    defer bag.deinit();
    var code_actions = std.array_list.Managed(CodeAction).init(allocator);
    for (lsp_code_actions) |lsp_code_action| {
        var action = try CodeAction.init(allocator, lsp_code_action);
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
    const result = try fromLsp(allocator, &.{
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
