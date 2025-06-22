const std = @import("std");
const main = @import("../main.zig");
const lsp = @import("../lsp.zig");
const log = @import("../log.zig");

const max_entries = 10;

pub const CompletionItem = struct {
    label: []const u8,
    filter_text: []const u8,
    replace_text: []const u8,
    allocator: std.mem.Allocator,

    pub fn from_lsp(allocator: std.mem.Allocator, item: lsp.types.CompletionItem) !CompletionItem {
        const text_edit = lsp.extract_text_edit(item) orelse return error.NoTextEdit;
        return .{
            .label = try allocator.dupe(u8, item.label),
            .filter_text = try allocator.dupe(u8, if (item.filterText) |ft| ft else item.label),
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
    /// List of `completion_items` indices
    /// Empty means completion menu is not visible
    display_items: std.ArrayList(usize),
    replace_range: ?lsp.types.Range,
    active_item: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CompletionMenu {
        return .{
            .completion_items = std.ArrayList(CompletionItem).init(allocator),
            .display_items = std.ArrayList(usize).init(allocator),
            .replace_range = null,
            .active_item = 0,
            .allocator = allocator,
        };
    }

    pub fn update_items(self: *CompletionMenu, lsp_items: []const lsp.types.CompletionItem) !void {
        log.log(@This(), "got {} completion items\n", .{lsp_items.len});
        if (lsp_items.len == 0) return;

        const prev_range_start = if (self.replace_range) |r| r.start else null;
        const text_edit = lsp.extract_text_edit(lsp_items[0]) orelse return;
        self.replace_range = text_edit.range;

        if (prev_range_start == null or !std.meta.eql(text_edit.range.start, prev_range_start.?)) {
            try self.reset_items(lsp_items);
        }

        const prompt = try main.editor.active_buffer.?.text_at(self.replace_range.?);
        log.log(@This(), "prompt {s}\n", .{prompt});

        self.display_items.clearRetainingCapacity();
        for (0..self.completion_items.items.len) |i| {
            const cmp_item = self.completion_items.items[i];
            if (std.mem.startsWith(u8, cmp_item.filter_text, prompt)) {
                try self.display_items.append(i);
                if (self.display_items.items.len >= max_entries) break;
            }
        }
        if (main.log_enabled) {
            if (self.display_items.items.len > 0) {
                log.log(@This(), "menu:\n", .{});
                for (self.display_items.items) |i| {
                    const item = self.completion_items.items[i];
                    std.debug.print("  {s}\n", .{item.label});
                }
            }
        }
    }

    pub fn reset_items(self: *CompletionMenu, lsp_items: []const lsp.types.CompletionItem) !void {
        log.log(@This(), "menu reset\n", .{});
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
        self.display_items.deinit();
    }
};
