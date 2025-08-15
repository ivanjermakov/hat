const std = @import("std");
const Allocator = std.mem.Allocator;
const lsp = @import("../lsp.zig");

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
            .edit_json = try std.json.stringifyAlloc(allocator, code_action.edit.?, .{}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *const CodeAction) void {
        self.allocator.free(self.title);
        self.allocator.free(self.edit_json);
    }
};
