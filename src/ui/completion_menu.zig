const std = @import("std");
const Allocator = std.mem.Allocator;

const buf = @import("../buffer.zig");
const cha = @import("../change.zig");
const core = @import("../core.zig");
const Span = core.Span;
const log = @import("../log.zig");
const lsp = @import("../lsp.zig");
const main = @import("../main.zig");
const uni = @import("../unicode.zig");

const max_entries = 10;

pub const CompletionItem = struct {
    item_json: []const u8,
    label: []const u8,
    filter_text: []const u8,
    replace_text: []const u8,
    detail: ?[]const u8,
    documentation: ?[]const u8,
    allocator: Allocator,

    pub fn fromLsp(allocator: Allocator, item: lsp.types.CompletionItem) !CompletionItem {
        const text_edit = lsp.extractTextEdit(item) orelse return error.NoTextEdit;
        const documentation = if (item.documentation) |doc| switch (doc) {
            .string => |s| try allocator.dupe(u8, s),
            .MarkupContent => |c| try allocator.dupe(u8, c.value),
        } else null;

        return .{
            .item_json = try std.json.stringifyAlloc(allocator, item, .{}),
            .label = try allocator.dupe(u8, item.label),
            .filter_text = try allocator.dupe(u8, if (item.filterText) |ft| ft else item.label),
            .replace_text = try allocator.dupe(u8, text_edit.newText),
            .detail = if (item.detail) |detail| try allocator.dupe(u8, detail) else null,
            .documentation = documentation,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CompletionItem) void {
        self.allocator.free(self.item_json);
        self.allocator.free(self.label);
        self.allocator.free(self.filter_text);
        self.allocator.free(self.replace_text);
        if (self.detail) |d| self.allocator.free(d);
        if (self.documentation) |d| self.allocator.free(d);
    }
};

pub const CompletionMenu = struct {
    completion_items: std.ArrayList(CompletionItem),
    /// List of `completion_items` indices
    /// Empty means completion menu is not visible
    display_items: std.ArrayList(usize),
    replace_range: ?lsp.types.Range,
    active_item: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator) CompletionMenu {
        return .{
            .completion_items = std.ArrayList(CompletionItem).init(allocator),
            .display_items = std.ArrayList(usize).init(allocator),
            .replace_range = null,
            .active_item = 0,
            .allocator = allocator,
        };
    }

    pub fn updateItems(self: *CompletionMenu, lsp_items: []const lsp.types.CompletionItem) !void {
        log.debug(@This(), "got {} completion items\n", .{lsp_items.len});
        if (lsp_items.len == 0) {
            self.reset();
            return;
        }
        errdefer self.reset();

        const prev_range_start = if (self.replace_range) |r| r.start else null;
        const text_edit = lsp.extractTextEdit(lsp_items[0]) orelse return;
        self.replace_range = text_edit.range;

        if (prev_range_start == null or !std.meta.eql(text_edit.range.start, prev_range_start.?)) {
            self.reset();
            for (lsp_items) |lsp_item| {
                const item = try CompletionItem.fromLsp(self.allocator, lsp_item);
                try self.completion_items.append(item);
            }
        }

        // TODO: replace_range might not end at cursor position
        const prompt = main.editor.active_buffer.rawTextAt(Span.fromLsp(self.replace_range.?));
        log.debug(@This(), "prompt {s}\n", .{prompt});

        self.display_items.clearRetainingCapacity();
        for (0..self.completion_items.items.len) |i| {
            const cmp_item = self.completion_items.items[i];
            if (std.ascii.startsWithIgnoreCase(cmp_item.filter_text, prompt)) {
                try self.display_items.append(i);
                if (self.display_items.items.len >= max_entries) break;
            }
        }
        self.active_item = 0;

        if (log.enabled) {
            if (self.display_items.items.len > 0) {
                log.debug(@This(), "menu:", .{});
                for (self.display_items.items) |i| {
                    const item = self.completion_items.items[i];
                    std.debug.print(" {s}", .{item.label});
                }
                std.debug.print("\n", .{});
            }
        }
        main.editor.dirty.draw = true;
    }

    pub fn reset(self: *CompletionMenu) void {
        for (self.completion_items.items) |*item| {
            item.deinit();
        }
        self.completion_items.clearRetainingCapacity();
        self.display_items.clearRetainingCapacity();
        self.active_item = 0;

        main.editor.dirty.draw = true;
    }

    pub fn deinit(self: *CompletionMenu) void {
        self.reset();
        self.completion_items.deinit();
        self.display_items.deinit();
    }

    pub fn nextItem(self: *CompletionMenu) !void {
        if (self.active_item == self.display_items.items.len - 1) {
            self.active_item = 0;
        } else {
            self.active_item += 1;
        }
        main.editor.dirty.draw = true;
    }

    pub fn prevItem(self: *CompletionMenu) !void {
        if (self.active_item == 0) {
            self.active_item = self.display_items.items.len - 1;
        } else {
            self.active_item -= 1;
        }
        main.editor.dirty.draw = true;
    }

    pub fn accept(self: *CompletionMenu) !void {
        defer self.reset();
        const item = self.completion_items.items[self.display_items.items[self.active_item]];
        log.debug(@This(), "accept item {}: {s}, replace text: {any}\n", .{ self.active_item, item.label, item.replace_text });
        const buffer = main.editor.active_buffer;

        const span = Span.fromLsp(self.replace_range.?);
        const new_text = try uni.utf8FromBytes(buffer.allocator, item.replace_text);
        defer self.allocator.free(new_text);
        var change = try cha.Change.initReplace(self.allocator, buffer, span, new_text);
        try buffer.appendChange(&change);
    }

    pub fn activeItem(self: *CompletionMenu) *CompletionItem {
        return &self.completion_items.items[self.display_items.items[self.active_item]];
    }
};
