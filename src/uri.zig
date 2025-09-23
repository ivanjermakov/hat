const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn toPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    const abs_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(abs_cwd);
    const parsed = try std.Uri.parse(uri);
    const path = try std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(parsed.path, .formatRaw)});
    defer allocator.free(path);
    return std.fs.path.relative(allocator, abs_cwd, path);
}

pub fn fromPath(allocator: Allocator, path: []const u8) ![]const u8 {
    const uri = std.Uri{ .scheme = "file", .path = .{ .raw = path }, .host = .empty };
    return try std.fmt.allocPrint(allocator, "{f}", .{uri});
}

pub fn fromRelativePath(allocator: Allocator, path: []const u8) ![]const u8 {
    const abs = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(abs);
    return try fromPath(allocator, abs);
}

test "fromPath" {
    const a = std.testing.allocator;
    const path = "/src/main.zig";
    const uri = try fromPath(a, path);
    defer a.free(uri);
    try std.testing.expectEqualStrings("file:///src/main.zig", uri);
}
