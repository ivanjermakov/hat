const std = @import("std");
const core = @import("../core.zig");
const ext = @import("../external.zig");
const log = @import("../log.zig");
const col = @import("../color.zig");
const buf = @import("../buffer.zig");

const Cursor = core.Cursor;
const Allocator = std.mem.Allocator;

pub fn pickFile(allocator: Allocator) ![]const u8 {
    const files = try ext.runExternalWait(allocator, &.{ "rg", "--files" }, null);
    defer allocator.free(files);

    var cmd = std.ArrayList([]const u8).init(allocator);
    try cmd.appendSlice(fzf_command);
    try cmd.append("--preview");
    try cmd.append("hat --printer {}");
    defer cmd.deinit();
    const out = try ext.runExternalWait(allocator, cmd.items, files);
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    return try allocator.dupe(u8, std.mem.trim(u8, out, "\n"));
}

pub const FindInFilesResult = struct {
    path: []const u8,
    position: Cursor,
};

pub fn findInFiles(allocator: Allocator) !FindInFilesResult {
    const rg_cmd = "rg -n --column --no-heading --smart-case {q}";
    var cmd = std.ArrayList([]const u8).init(allocator);
    defer cmd.deinit();
    try cmd.appendSlice(fzf_command);
    try cmd.append("--preview");
    try cmd.append("hat --printer --term-height=$FZF_PREVIEW_LINES --highlight-line={2} {1}");
    try cmd.appendSlice(&.{ "--bind", std.fmt.comptimePrint("start:reload:{s}", .{rg_cmd}) });
    try cmd.appendSlice(&.{ "--bind", std.fmt.comptimePrint("change:reload:sleep 0.1; {s} || true", .{rg_cmd}) });
    try cmd.appendSlice(&.{ "--delimiter", ":" });
    const out = try ext.runExternalWait(allocator, cmd.items, null);
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    var iter = std.mem.splitScalar(u8, out, ':');
    return .{
        .path = try allocator.dupe(u8, iter.next().?),
        .position = .{
            .row = try std.fmt.parseInt(i32, iter.next().?, 10) - 1,
            .col = try std.fmt.parseInt(i32, iter.next().?, 10) - 1,
        },
    };
}

pub fn pickBuffer(allocator: Allocator, buffers: []const *buf.Buffer) ![]const u8 {
    var bufs = std.ArrayList(u8).init(allocator);
    for (buffers) |buffer| {
        const s = try std.fmt.allocPrint(
            allocator,
            "{s}:{}:{}\n",
            .{ buffer.path, buffer.cursor.row + 1, buffer.cursor.col + 1 },
        );
        defer allocator.free(s);
        try bufs.appendSlice(s);
    }
    const bufs_str = try bufs.toOwnedSlice();
    defer allocator.free(bufs_str);

    var cmd = std.ArrayList([]const u8).init(allocator);
    defer cmd.deinit();
    try cmd.appendSlice(fzf_command);
    try cmd.append("--preview");
    try cmd.append("hat --printer --term-height=$FZF_PREVIEW_LINES --highlight-line={2} {1}");
    try cmd.appendSlice(&.{ "--delimiter", ":" });

    const out = try ext.runExternalWait(allocator, cmd.items, bufs_str);
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    var iter = std.mem.splitScalar(u8, out, ':');
    return try allocator.dupe(u8, iter.next().?);
}

const fzf_command: []const []const u8 = &.{
    "fzf",
    "--cycle",
    "--layout=reverse",
    "--color=dark",
    "--preview-window=noborder",
    "--marker=",
    "--pointer=",
    "--separator=",
    "--scrollbar=",
    "--no-info",
    "--no-hscroll",
    "--color=prompt:-1",
    std.fmt.comptimePrint("--color=hl:#{s}", .{col.color.blue.toHexStr()}),
    std.fmt.comptimePrint("--color=hl+:#{s}", .{col.color.blue.toHexStr()}),
    std.fmt.comptimePrint("--color=bg+:#{s}", .{col.color.gray4.toHexStr()}),
};
