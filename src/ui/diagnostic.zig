const std = @import("std");
const Allocator = std.mem.Allocator;

const core = @import("../core.zig");
const Span = core.Span;

const lsp = @import("../lsp.zig");

pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
    severity: lsp.types.DiagnosticSeverity,
    raw_json: []const u8,
    allocator: Allocator,

    pub fn fromLsp(allocator: Allocator, lsp_diagnostic: lsp.types.Diagnostic) !Diagnostic {
        return .{
            .span = Span.fromLsp(lsp_diagnostic.range),
            .message = try allocator.dupe(u8, lsp_diagnostic.message),
            .severity = lsp_diagnostic.severity orelse .Error,
            .raw_json = try std.json.Stringify.valueAlloc(allocator, lsp_diagnostic, .{}),
            .allocator = allocator,
        };
    }

    pub fn toLsp(self: *const Diagnostic, arena: Allocator) !lsp.types.Diagnostic {
        return try std.json.parseFromSliceLeaky(lsp.types.Diagnostic, arena, self.raw_json, .{});
    }

    pub fn deinit(self: *Diagnostic) void {
        self.allocator.free(self.message);
        self.allocator.free(self.raw_json);
    }

    pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
        return a.span.start.order(b.span.start) == .lt;
    }
};
