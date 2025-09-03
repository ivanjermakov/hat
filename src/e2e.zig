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

fn e2eSetup() !bool {
    main.std_err_file_writer = main.std_err.writer(&main.std_err_buf);
    log.log_writer = &main.std_err_file_writer.interface;
    log.init(log.log_writer, null);
    if (e2eSkip()) return false;
    try createTmpFiles();
    return true;
}

fn e2eSkip() bool {
    if (std.posix.getenv("SKIP_E2E")) |skip| {
        if (std.mem.eql(u8, skip, "true")) {
            log.warn(@This(), "skipped e2e test\n", .{});
            return true;
        }
    }
    return false;
}

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
    main.std_err_file_writer = main.std_err.writer(&main.std_err_buf);
    main.std_err_writer = &main.std_err_file_writer.interface;

    const editor_thread = try std.Thread.spawn(.{ .allocator = allocator }, startEditor, .{});
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

test "e2e open quit" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    log.init(main.std_err_writer, null);

    sleep(100 * ms);
    try setup.tty_in.writeAll("q");

    setup.handle.join();
}

test "e2e lsp completion accept" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("ostd.debug.pri");
    sleep(200 * ms);
    try setup.tty_in.writeAll("\n();\x1b wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\std.debug.print();
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}

test "e2e update indents" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("i    \x1b");
    try setup.tty_in.writeAll("=");
    try setup.tty_in.writeAll(" wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}
