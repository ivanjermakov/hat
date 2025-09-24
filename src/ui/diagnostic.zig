const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("../core.zig");
const Span = core.Span;

const lsp = @import("../lsp.zig");

pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
    allocator: Allocator,

    pub fn fromLsp(allocator: Allocator, lsp_diagnostic: lsp.types.Diagnostic) !Diagnostic {
        return .{
            .span = Span.fromLsp(lsp_diagnostic.range),
            .message = try allocator.dupe(u8, lsp_diagnostic.message),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Diagnostic) void {
        self.allocator.free(self.message);
    }

    pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        return a.span.start.order(b.span.start) == .lt;
    }
};
