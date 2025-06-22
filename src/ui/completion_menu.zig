const std = @import("std");
const lsp = @import("../lsp.zig");
const log = @import("../log.zig");

pub const CompletionItem = struct {
    label: []const u8,
    replace_text: []const u8,
    allocator: std.mem.Allocator,

    pub fn from_lsp(allocator: std.mem.Allocator, item: lsp.types.CompletionItem) !CompletionItem {
        const text_edit = lsp.extract_text_edit(item) orelse return error.NoTextEdit;
        return .{
            .label = try allocator.dupe(u8, item.label),
            .replace_text = try allocator.dupe(u8, text_edit.newText),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompletionItem) void {
        self.allocator.free(self.label);
        self.allocator.free(self.replace_text);
    }
};

pub const CompletionMenu = struct {
    completion_items: std.ArrayList(CompletionItem),
    replace_range: ?lsp.types.Range,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompletionMenu {
        return .{
            .completion_items = std.ArrayList(CompletionItem).init(allocator),
            .replace_range = null,
            .allocator = allocator,
        };
    }

    pub fn update_items(self: *CompletionMenu, lsp_items: []const lsp.types.CompletionItem) !void {
        log.log(@This(), "got {} completion items\n", .{lsp_items.len});
        if (lsp_items.len == 0) return;

        const prev_range_start = if (self.replace_range) |r| r.start else null;
        const text_edit = lsp.extract_text_edit(lsp_items[0]) orelse return;
        self.replace_range = text_edit.range;

        if (prev_range_start != null and
            std.meta.eql(text_edit.range.start, prev_range_start.?))
        {
            log.log(@This(), "same replace range start\n", .{});
            return;
        }

        for (self.completion_items.items) |*item| {
            item.deinit();
        }
        self.completion_items.clearRetainingCapacity();

        for (lsp_items) |lsp_item| {
            const item = try CompletionItem.from_lsp(self.allocator, lsp_item);
            try self.completion_items.append(item);
        }
    }

    pub fn deinit(self: *CompletionMenu) void {
        for (self.completion_items.items) |*item| {
            item.deinit();
        }
        self.completion_items.deinit();
    }
};
