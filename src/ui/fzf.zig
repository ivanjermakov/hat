const std = @import("std");
const ext = @import("../external.zig");
const log = @import("../log.zig");
const col = @import("../color.zig");

pub fn pickFile(allocator: std.mem.Allocator) ![]const u8 {
    const files = try ext.runExternalWait(allocator, &.{ "rg", "--files" }, null);
    defer allocator.free(files);

    const out = try ext.runExternalWait(allocator, fzf_command, files);
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    return try allocator.dupe(u8, std.mem.trim(u8, out, "\n"));
}

const fzf_command: []const []const u8 = &.{
    "fzf",
    "--color=dark",
    "--preview",
    "hat --printer {}",
    "--preview-window=noborder",
    "--marker=",
    "--pointer=",
    "--separator=",
    "--scrollbar=",
    "--no-info",
    "--color=prompt:-1",
    std.fmt.comptimePrint("--color=hl:#{s}", .{col.color.blue.toHexStr()}),
    std.fmt.comptimePrint("--color=hl+:#{s}", .{col.color.blue.toHexStr()}),
    std.fmt.comptimePrint("--color=bg+:#{s}", .{col.color.gray4.toHexStr()}),
};
