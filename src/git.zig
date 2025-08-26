const std = @import("std");
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const ext = @import("external.zig");
const log = @import("log.zig");

pub fn gitRoot(allocator: Allocator, file_path: []const u8) !?[]const u8 {
    const abs_path = try std.fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(abs_path);

    var dir_opt: ?[]const u8 = abs_path;
    while (dir_opt) |dir| {
        std.posix.access(dir, std.posix.F_OK) catch break;
        const git_dir = try path.join(allocator, &.{ dir, ".git" });
        defer allocator.free(git_dir);
        std.posix.access(git_dir, std.posix.F_OK) catch {
            dir_opt = path.dirname(dir);
            continue;
        };
        return try allocator.dupe(u8, dir);
    }
    return null;
}

pub fn show(allocator: Allocator, file_path: []const u8) !?[]const u8 {
    var path_arg = std.array_list.Managed(u8).init(allocator);
    defer path_arg.deinit();
    try path_arg.appendSlice(":");
    try path_arg.appendSlice(file_path);
    const args = .{ "git", "--no-pager", "show", path_arg.items };
    var exit_code: u8 = undefined;
    const content = try ext.runExternalWait(allocator, &args, null, &exit_code);
    errdefer allocator.free(content);
    if (exit_code != 0) return error.GitError;
    return content;
}

pub fn diffHunks(allocator: Allocator, file_before: []const u8, file_after: []const u8) !?[]const Hunk {
    const args = .{ "git", "--no-pager", "diff", "--unified=0", "--no-color", file_before, file_after };
    var exit_code: u8 = undefined;
    const diff = try ext.runExternalWait(allocator, &args, null, &exit_code);
    if (exit_code == 0) return null;
    if (exit_code != 1) return error.GitError;
    defer allocator.free(diff);
    return try parseDiff(allocator, diff);
}

pub const HunkType = enum {
    add,
    modify,
    delete,

    pub fn fromCounts(added: usize, deleted: usize) HunkType {
        std.debug.assert(!(added == 0 and deleted == 0));
        if (added > 0 and deleted > 0) return .modify;
        if (added > 0) return .add;
        return .delete;
    }
};

pub const Hunk = struct {
    type: HunkType,
    line: usize,
    len: usize,
};

pub fn parseDiff(allocator: Allocator, diff: []const u8) ![]const Hunk {
    var hunks = std.array_list.Managed(Hunk).init(allocator);
    var hunk_iter = std.mem.splitSequence(u8, diff, "\n@@");
    // skip file info before first hunk
    _ = hunk_iter.next();
    while (hunk_iter.next()) |hunk| {
        var adds: usize = 0;
        var deletes: usize = 0;
        var line_iter = std.mem.splitSequence(u8, hunk, "\n");
        while (line_iter.next()) |line| {
            if (line.len > 0) {
                if (line[0] == '+') adds += 1;
                if (line[0] == '-') deletes += 1;
            }
        }
        const stats_line = hunk[std.mem.indexOf(u8, hunk, "+").?..std.mem.indexOf(u8, hunk, "\n").?];
        const stats = stats_line[0..std.mem.indexOf(u8, stats_line, " ").?];
        if (std.mem.indexOf(u8, stats, ",")) |comma_idx| {
            const start_line = try std.fmt.parseInt(usize, stats[1..comma_idx], 10);
            const len = try std.fmt.parseInt(usize, stats[comma_idx + 1 ..], 10);
            try hunks.append(.{ .type = .fromCounts(adds, deletes), .line = start_line, .len = len });
        } else {
            const start_line = try std.fmt.parseInt(usize, stats[1..], 10);
            try hunks.append(.{ .type = .fromCounts(adds, deletes), .line = start_line, .len = 0 });
        }
    }
    return hunks.toOwnedSlice();
}

test "parseDiff" {
    const allocator = std.testing.allocator;
    const out =
        \\diff --git 1/tmp/a 2/tmp/b
        \\index d121fe0..c308f6e 100644
        \\--- 1/tmp/a
        \\+++ 2/tmp/b
        \\@@ -1 +0,0 @@
        \\-const cha = @import("change.zig");
        \\@@ -3,2 +2,2 @@ const clp = @import("clipboard.zig");
        \\-const core = @import("core.zig");
        \\-const Span = core.Span;
        \\+const core = @import("core.ziggg");
        \\+const Span = core.Spannn;
        \\@@ -7,0 +7,2 @@ const Dimensions = core.Dimensions;
        \\+const Dimensions = core.Dimensions;
        \\+const Dimensions = core.Dimensions;
    ;
    const hunks = try parseDiff(allocator, out);
    defer allocator.free(hunks);

    try std.testing.expectEqual(hunks.len, 3);
    try std.testing.expectEqualDeep(hunks[0], Hunk{ .type = .delete, .line = 0, .len = 0 });
    try std.testing.expectEqualDeep(hunks[1], Hunk{ .type = .modify, .line = 2, .len = 2 });
    try std.testing.expectEqualDeep(hunks[2], Hunk{ .type = .add, .line = 7, .len = 2 });
}

test "parseDiff blank lines" {
    const allocator = std.testing.allocator;
    const out =
        \\diff --git 1/tmp/a 2/tmp/b
        \\index 285f63d..96f799d 100644
        \\--- 1/tmp/hat_staged
        \\+++ 2/src/main.zig
        \\@@ -34,0 +35 @@ pub var tty_in: std.fs.File = undefined;
        \\+
        \\@@ -37 +37,0 @@ pub var term: ter.Terminal = undefined;
        \\-
    ;
    const hunks = try parseDiff(allocator, out);
    defer allocator.free(hunks);

    try std.testing.expectEqual(hunks.len, 2);
    try std.testing.expectEqualDeep(hunks[0], Hunk{ .type = .add, .line = 35, .len = 0 });
    try std.testing.expectEqualDeep(hunks[1], Hunk{ .type = .delete, .line = 37, .len = 0 });
}
