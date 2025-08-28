const std = @import("std");
const ms = std.time.ns_per_ms;
const sleep = std.Thread.sleep;
const File = std.fs.File;

const core = @import("core.zig");
const Dimensions = core.Dimensions;
const edi = @import("editor.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const ter = @import("terminal.zig");

fn createTmpFiles() !void {
    const tmp_file = try std.fs.cwd().createFile("/tmp/hat_e2e.zig", .{ .truncate = true });
    defer tmp_file.close();
    try tmp_file.writeAll(
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    );
}

fn startEditor(allocator: std.mem.Allocator, tty_in: File) !void {
    log.init();
    log.level = .@"error";

    main.tty_in = tty_in;
    const stdout_pipe = try std.posix.pipe();
    const mock_stdout: File = .{ .handle = stdout_pipe[1] };
    main.std_out_writer = mock_stdout.writer(&main.std_out_buf);

    const term_size = Dimensions{ .width = 40, .height = 40 };

    main.term = try ter.Terminal.init(allocator, &main.std_out_writer.interface, term_size);
    defer main.term.deinit();

    main.editor = try edi.Editor.init(allocator, .{});
    defer main.editor.deinit();

    try main.editor.openBuffer("/tmp/hat_e2e.zig");

    try main.startEditor(allocator);
    defer main.editor.disconnect() catch {};
}

test "e2e" {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    try createTmpFiles();

    const tty_in_pipe = try std.posix.pipe();
    const mock_tty_in: File = .{ .handle = tty_in_pipe[0] };
    const mock_tty_out: File = .{ .handle = tty_in_pipe[1] };
    const editor_thread = try std.Thread.spawn(.{}, startEditor, .{allocator, mock_tty_in});

    sleep(50 * ms);
    try mock_tty_out.writeAll("q");

    editor_thread.join();
}
