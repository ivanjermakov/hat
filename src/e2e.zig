const std = @import("std");
const allocator = std.testing.allocator;
const ms = std.time.ns_per_ms;
const sleep = std.Thread.sleep;
const File = std.fs.File;

const core = @import("core.zig");
const Dimensions = core.Dimensions;
const Cursor = core.Cursor;
const edi = @import("editor.zig");
const log = @import("log.zig");
const main = @import("main.zig");
const ter = @import("terminal.zig");
const ur = @import("uri.zig");

/// E2E test suite requires zls LSP server
/// Start test suite with SKIP_E2E=true to skip E2E tests
fn e2eSetup() !bool {
    main.std_err_file_writer = main.std_err.writer(&main.std_err_buf);
    log.level = .debug;
    log.log_writer = &main.std_err_file_writer.interface;
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

    main.editor = try edi.Editor.init(allocator);
    defer main.editor.deinit();

    try main.editor.openBuffer(try ur.fromPath(allocator, "/tmp/hat_e2e.zig"));

    try main.startEditor(allocator);
    defer main.editor.disconnect() catch {};
}

test "e2e open quit" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

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

test "e2e lsp go to definition" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("10lj d");

    sleep(100 * ms);
    const buffer = main.editor.active_buffer;
    try std.testing.expectEqualDeep(Cursor{ .row = 1, .col = 7 }, buffer.cursor);
    try setup.tty_in.writeAll(" wq");

    setup.handle.join();
}

test "e2e lsp rename" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(200 * ms);
    try setup.tty_in.writeAll("w n\x7f\x7f\x7ffoo\n");
    sleep(100 * ms);
    try setup.tty_in.writeAll(" wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\const foo = @import("std");
        \\pub fn main() !void {
        \\    foo.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}

test "e2e lsp hover" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(200 * ms);
    try setup.tty_in.writeAll("14l2j");
    sleep(100 * ms);
    try setup.tty_in.writeAll("K");

    sleep(100 * ms);
    try std.testing.expect(main.editor.hover_contents != null);
    try std.testing.expect(main.editor.hover_contents.?.len > 0);
    try setup.tty_in.writeAll("q");

    setup.handle.join();
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

test "e2e marco record replay count" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("rroabc\x1br");
    try setup.tty_in.writeAll("5@r");
    try setup.tty_in.writeAll(" wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\abc
        \\abc
        \\abc
        \\abc
        \\abc
        \\abc
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}

test "e2e dot repeat" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("oabc\x1b");
    sleep(100 * ms);
    try setup.tty_in.writeAll(".....");
    try setup.tty_in.writeAll(" wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\const std = @import("std");
        \\abc
        \\abc
        \\abc
        \\abc
        \\abc
        \\abc
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}

test "e2e line join" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("JgJ wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\const std = @import("std"); pub fn main() !void {    std.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}

test "e2e find token" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("w*");

    sleep(100 * ms);
    const buffer = main.editor.active_buffer;
    try std.testing.expectEqualDeep(Cursor{ .row = 0, .col = 21 }, buffer.cursor);
    try setup.tty_in.writeAll("#");

    sleep(100 * ms);
    try std.testing.expectEqualDeep(Cursor{ .row = 0, .col = 6 }, buffer.cursor);
    try setup.tty_in.writeAll("q");

    setup.handle.join();
}

test "e2e backspace delete" {
    if (!try e2eSetup()) return;
    const setup = try setupEditor();

    sleep(100 * ms);
    try setup.tty_in.writeAll("wi\x7f\x1b[3~\x1b wq");

    setup.handle.join();

    const tmp_file = try std.fs.cwd().openFile("/tmp/hat_e2e.zig", .{});
    defer tmp_file.close();
    const tmp_file_content = try tmp_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(tmp_file_content);
    try std.testing.expectEqualStrings(
        \\consttd = @import("std");
        \\pub fn main() !void {
        \\    std.debug.print("hello!\n", .{});
        \\}
        \\
    , tmp_file_content);
}
