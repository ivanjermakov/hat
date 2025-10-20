const std = @import("std");
const Allocator = std.mem.Allocator;

const buf = @import("../buffer.zig");
const col = @import("../color.zig");
const Color = col.color;
const core = @import("../core.zig");
const Cursor = core.Cursor;
const SpanFlat = core.SpanFlat;
const ext = @import("../external.zig");
const log = @import("../log.zig");
const lsp = @import("../lsp.zig");
const uri = @import("../uri.zig");

pub fn pickFile(allocator: Allocator) ![]const u8 {
    const files = try ext.runExternalWait(allocator, &.{ "rg", "--files" }, .{});
    defer allocator.free(files);

    const cmd = fzf_command ++ .{ "--preview", "hat --printer {}" };
    const out = try ext.runExternalWait(allocator, cmd, .{ .input = files });
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    return try allocator.dupe(u8, std.mem.trim(u8, out, "\n"));
}

pub const FindResult = struct {
    path: []const u8,
    position: Cursor,

    pub fn init(allocator: Allocator, fzf_out: []const u8) !FindResult {
        var iter = std.mem.splitScalar(u8, std.mem.trimEnd(u8, fzf_out, "\n"), ':');
        return .{
            .path = try allocator.dupe(u8, iter.next().?),
            .position = .{
                .row = try std.fmt.parseInt(i32, iter.next().?, 10) - 1,
                .col = try std.fmt.parseInt(i32, iter.next().?, 10) - 1,
            },
        };
    }
};

pub fn findInFiles(allocator: Allocator) !FindResult {
    const rg_cmd = "rg -n --column --no-heading --smart-case {q}";
    const cmd = fzf_cmd_with_preview ++ .{
        "--bind",
        std.fmt.comptimePrint("start:reload:{s}", .{rg_cmd}),
        "--bind",
        std.fmt.comptimePrint("change:reload:sleep 0.1; {s} || true", .{rg_cmd}),
    };
    const out = try ext.runExternalWait(allocator, cmd, .{});
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    return .init(allocator, out);
}

pub fn pickBuffer(allocator: Allocator, buffers: []const *buf.Buffer) ![]const u8 {
    var bufs: std.io.Writer.Allocating = .init(allocator);
    defer bufs.deinit();
    for (buffers) |buffer| {
        try bufs.writer.print(
            "{s}:{}:{}\n",
            .{ buffer.path, buffer.cursor.row + 1, buffer.cursor.col + 1 },
        );
    }

    const out = try ext.runExternalWait(allocator, fzf_cmd_with_preview, .{ .input = bufs.written() });
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    var iter = std.mem.splitScalar(u8, out, ':');
    return try allocator.dupe(u8, iter.next().?);
}

pub fn pickLspLocation(allocator: Allocator, locations: []const lsp.types.Location) !FindResult {
    var bufs: std.io.Writer.Allocating = .init(allocator);
    defer bufs.deinit();
    for (locations) |location| {
        const start = location.range.start;
        const path = try uri.toPath(allocator, location.uri);
        defer allocator.free(path);
        try bufs.writer.print(
            "{s}:{}:{}:\n",
            .{ path, start.line + 1, start.character + 1 },
        );
    }
    const bufs_str = try bufs.toOwnedSlice();
    defer allocator.free(bufs_str);

    const out = try ext.runExternalWait(allocator, fzf_cmd_with_preview, .{ .input = bufs_str });
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    return .init(allocator, out);
}

pub fn pickSymbol(allocator: Allocator, buffer: *const buf.Buffer, symbols: []const SpanFlat) !FindResult {
    var lines: std.io.Writer.Allocating = .init(allocator);
    defer lines.deinit();
    for (symbols) |symbol| {
        const pos = buffer.posToCursor(symbol.start);
        const symbol_name = buffer.content_raw.items[symbol.start..symbol.end];
        try lines.writer.print(
            "{s}:{}:{}\n",
            .{ symbol_name, pos.row + 1, pos.col + 1 },
        );
    }

    const preview_cmd = try std.fmt.allocPrint(
        allocator,
        "hat --printer --term-height=$FZF_PREVIEW_LINES --highlight-line={{2}} {s}",
        .{buffer.path},
    );
    defer allocator.free(preview_cmd);

    const cmd: []const []const u8 = fzf_command ++ .{ "--preview", preview_cmd, "--delimiter", ":" };
    const out = try ext.runExternalWait(allocator, cmd, .{ .input = lines.written() });
    defer allocator.free(out);
    if (out.len == 0) return error.EmptyOut;
    return .init(allocator, out);
}

const fzf_cmd_with_preview: []const []const u8 = fzf_command ++ .{
    "--preview",
    "hat --printer --term-height=$FZF_PREVIEW_LINES --highlight-line={2} {1}",
    "--delimiter",
    ":",
};

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
    std.fmt.comptimePrint("--color=hl:#{s}", .{Color.blue.toHexStr()}),
    std.fmt.comptimePrint("--color=hl+:#{s}", .{Color.blue.toHexStr()}),
    std.fmt.comptimePrint("--color=bg+:#{s}", .{Color.gray4.toHexStr()}),
};
