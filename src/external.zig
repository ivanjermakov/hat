const std = @import("std");
const main = @import("main.zig");
const log = @import("log.zig");

pub fn runExternalWait(allocator: std.mem.Allocator, cmd: []const []const u8, input: ?[]const u8) ![]const u8 {
    try main.term.switchBuf(false);
    log.log(@This(), "running external command {any}\n", .{cmd});
    var child = std.process.Child.init(cmd, allocator);
    if (input != null) child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;

    try child.spawn();
    try child.waitForSpawn();

    if (input) |inp| try child.stdin.?.writeAll(inp);

    const res = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize));

    const code = (try child.wait()).Exited;
    log.log(@This(), "external command exit code: {}\n", .{code});
    try main.term.switchBuf(true);
    main.editor.needs_redraw = true;

    return res;
}
