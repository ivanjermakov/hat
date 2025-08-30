const std = @import("std");
const allocator = std.testing.allocator;
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

const Setup = struct {
    handle: std.Thread,
    tty_in: std.fs.File,
    stdout: std.fs.File,
};

fn setupEditor() !Setup {
    const tty_in_pipe = try std.posix.pipe();
    const mock_tty_in_read: File = .{ .handle = tty_in_pipe[0] };
    const mock_tty_in_write: File = .{ .handle = tty_in_pipe[1] };

    main.tty_in = mock_tty_in_read;
    const stdout_pipe = try std.posix.pipe();
    const mock_stdout: File = .{ .handle = stdout_pipe[1] };
    main.std_out = mock_stdout;
    main.std_out_writer = mock_stdout.writer(&main.std_out_buf);
    main.std_err_writer = main.std_out.writer(&main.std_err_buf);

    const editor_thread = try std.Thread.spawn(.{}, startEditor, .{});
    return .{ .handle = editor_thread, .tty_in = mock_tty_in_write, .stdout = main.std_out };
}

fn startEditor() !void {
    const term_size = Dimensions{ .width = 40, .height = 40 };

    main.term = try ter.Terminal.init(allocator, &main.std_out_writer.interface, term_size);
    defer main.term.deinit();

    main.editor = try edi.Editor.init(allocator, .{});
    defer main.editor.deinit();

    try main.editor.openBuffer("/tmp/hat_e2e.zig");

    try main.startEditor(allocator);
    defer main.editor.disconnect() catch {};
}

fn skipE2e() bool {
    if (std.posix.getenv("SKIP_E2E")) |skip| {
        if (std.mem.eql(u8, skip, "true")) {
            log.warn(@This(), "skipped e2e test\n", .{});
            return true;
        }
    }
    return false;
}

test "e2e" {
    log.init();
    log.level = .warn;
    if (skipE2e()) return;
    try createTmpFiles();

    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("q");

    setup.handle.join();
}
