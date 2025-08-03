const std = @import("std");

const Allocator = std.mem.Allocator;

pub fn extractPath(uri: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, uri, prefix)) {
        return uri[prefix.len..];
    }
    return null;
}

pub fn toPath(allocator: Allocator, uri: []const u8) ![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.NotUri;
    const abs_cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(abs_cwd);
    return std.fs.path.relative(allocator, abs_cwd, uri[prefix.len..]);
}
