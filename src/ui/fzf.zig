const std = @import("std");
const ext = @import("../external.zig");
const log = @import("../log.zig");

pub fn pickFile(allocator: std.mem.Allocator) ![]const u8 {
    const files = try ext.runExternalWait(allocator, &.{ "rg", "--files" }, null);
    defer allocator.free(files);

    const out = try ext.runExternalWait(allocator, &.{ "fzf", "--color=dark", "--preview", "cat {}" }, files);
    defer allocator.free(out);

    return try allocator.dupe(u8, std.mem.trim(u8, out, "\n"));
}
