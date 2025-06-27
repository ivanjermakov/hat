const std = @import("std");
const builtin = @import("builtin");
const dl = std.DynLib;
const edi = @import("editor.zig");
const inp = @import("input.zig");
const ft = @import("file_type.zig");
const buf = @import("buffer.zig");
const co = @import("color.zig");
const ter = @import("terminal.zig");
const lsp = @import("lsp.zig");
const log = @import("log.zig");
const uni = @import("unicode.zig");

const Args = struct {
    path: ?[]u8,
    log: bool,
};

pub const sleep_ns = 16 * 1e6;
pub var allocator: std.mem.Allocator = undefined;
pub const std_out = std.io.getStdOut();
pub const std_in = std.io.getStdOut();
pub var tty_in: std.fs.File = undefined;

pub var editor: edi.Editor = undefined;
pub var term: ter.Terminal = undefined;

pub var log_enabled = true;
pub var args: Args = .{
    .path = null,
    .log = false,
};
pub var key_queue: std.ArrayList(inp.Key) = undefined;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.c_allocator;

    log.log(@This(), "logging enabled\n", .{});

    tty_in = try std.fs.cwd().openFile("/dev/tty", .{});

    var cmd_args = std.process.args();
    _ = cmd_args.skip();
    while (cmd_args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            args.log = true;
            continue;
        }
        args.path = @constCast(arg);
    }
    log_enabled = args.log;

    key_queue = std.ArrayList(inp.Key).init(allocator);
    defer {
        for (key_queue.items) |key| if (key.printable) |p| allocator.free(p);
        key_queue.deinit();
    }

    const path = args.path orelse return error.NoPath;
    log.log(@This(), "opening file at path {s}\n", .{path});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    editor = try edi.Editor.init(allocator);
    defer editor.deinit();

    var buffer = try buf.Buffer.init(allocator, path, file_content);
    editor.needs_reparse = true;
    try editor.buffers.append(&buffer);
    editor.active_buffer = &buffer;

    term = try ter.Terminal.init(std_out.writer().any(), try ter.terminalSize());
    defer term.deinit();

    var lsp_conn: ?lsp.LspConnection = if (buffer.file_type.lsp) |lsp_conf| try lsp.LspConnection.connect(allocator, &lsp_conf) else null;
    defer if (lsp_conn) |*conn| conn.deinit();

    main_loop: while (true) {
        if (lsp_conn) |*conn| try conn.update();

        const needs_handle_mappings = try term.update_input(allocator);
        if (needs_handle_mappings) {
            handle_mappings: while (key_queue.items.len > 0) {
                // log.log(@This(), "keys: {any}\n", .{keys.items});
                const key = key_queue.orderedRemove(0);
                defer if (key.printable) |p| allocator.free(p);

                const code = key.code;
                var ch: ?u8 = null;
                if (key.printable != null and key.printable.?.len == 1) ch = key.printable.?[0];

                const multiple_key = key_queue.items.len > 0;
                const normal_or_select = editor.mode.normalOrSelect();
                const cmp_menu_active = editor.mode == .insert and
                    editor.completion_menu.display_items.items.len > 0;

                // cmp_menu
                if (cmp_menu_active and code == .up) {
                    editor.completion_menu.prevItem();
                } else if (cmp_menu_active and code == .down) {
                    editor.completion_menu.nextItem();
                } else if (cmp_menu_active and ch == '\n') {
                    try editor.completion_menu.accept();

                    // global
                } else if (code == .up) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1, .col = 0 }));
                } else if (code == .down) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1, .col = 0 }));
                } else if (code == .left) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 0, .col = -1 }));
                } else if (code == .right) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 0, .col = 1 }));
                } else if (code == .escape) {
                    try buffer.enterMode(.normal);

                    // normal or select mode
                } else if (normal_or_select and ch == 'q') {
                    break :main_loop;
                } else if (normal_or_select and ch == 'i') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1, .col = 0 }));
                } else if (normal_or_select and ch == 'k') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1, .col = 0 }));
                } else if (normal_or_select and ch == 'j') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 0, .col = -1 }));
                } else if (normal_or_select and ch == 'l') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 0, .col = 1 }));
                } else if (normal_or_select and ch == 'w') {
                    try buffer.moveToNextWord();
                } else if (normal_or_select and ch == 'W') {
                    try buffer.moveToPrevWord();

                    // select mode
                } else if (editor.mode == .select and ch == 'd') {
                    try buffer.selectionDelete();
                    try buffer.enterMode(.normal);

                    // normal mode
                } else if (editor.mode == .normal and ch == 's') {
                    try buffer.enterMode(.select);
                } else if (editor.mode == .normal and ch == 'h') {
                    try buffer.enterMode(.insert);

                    // insert mode
                } else if (editor.mode == .insert and code == .delete) {
                    try buffer.deleteChar();
                } else if (editor.mode == .insert and code == .backspace) {
                    try buffer.deletePrevChar();
                    editor.needs_completion = true;
                } else if (editor.mode == .insert and key.printable != null) {
                    const printable = try uni.utf8FromBytes(allocator, key.printable.?);
                    defer allocator.free(printable);
                    try buffer.insertText(printable);
                    editor.needs_completion = true;

                    // multiple-key
                } else if (multiple_key) {
                    const key2 = key_queue.orderedRemove(0);
                    defer if (key2.printable) |p| allocator.free(p);
                    var ch2: ?u8 = null;
                    if (key2.printable != null and key2.printable.?.len == 1) ch2 = key2.printable.?[0];

                    if (editor.mode == .normal and ch == ' ' and ch2 == 'd') {
                        if (lsp_conn) |*conn| try conn.goToDefinition();
                    } else if (normal_or_select and ch == 'g' and ch2 == 'i') {
                        try buffer.moveCursor(.{ .row = 0, .col = buffer.cursor.col });
                    } else if (normal_or_select and ch == 'g' and ch2 == 'k') {
                        try buffer.moveCursor(.{
                            .row = @as(i32, @intCast(buffer.content.items.len)) - 1,
                            .col = buffer.cursor.col,
                        });
                    } else if (normal_or_select and ch == 'g' and ch2 == 'l') {
                        const line = buffer.content.items[@intCast(buffer.cursor.row)].items;
                        try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = @intCast(line.len) });
                    } else if (normal_or_select and ch == 'g' and ch2 == 'j') {
                        try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = 0 });
                    } else {
                        // no matches, reinsert key2 and try it as a single key mapping on next iteration
                        try key_queue.insert(0, try key2.clone(allocator));
                        continue :handle_mappings;
                    }
                } else {
                    if (key_queue.items.len == 0) {
                        // no matches, reinsert key and wait for more keys
                        try key_queue.insert(0, try key.clone(allocator));
                        break :handle_mappings;
                    } else {
                        continue :handle_mappings;
                    }
                }
            }
        }

        editor.needs_redraw = editor.needs_redraw or editor.needs_reparse;
        if (editor.needs_reparse) {
            editor.needs_reparse = false;
            try buffer.tsParse();
            try buffer.updateLinePositions();
            if (lsp_conn) |*conn| try conn.didChange();
        }
        if (editor.needs_redraw) {
            editor.needs_redraw = false;
            try term.draw();
        } else if (editor.needs_update_cursor) {
            editor.needs_update_cursor = false;
            try term.updateCursor();
        }
        if (editor.needs_completion) {
            editor.needs_completion = false;
            if (lsp_conn) |*conn| try conn.sendCompletionRequest();
        }
        std.time.sleep(sleep_ns);
    }

    if (lsp_conn) |*conn| {
        log.log(@This(), "disconnecting lsp client\n", .{});
        try conn.disconnect();
        disconnect_loop: while (true) {
            if (conn.status == .Closed) break :disconnect_loop;
            try conn.update();
        }
    }
}

comptime {
    std.testing.refAllDecls(@This());
}

pub fn testSetup() !void {
    allocator = std.testing.allocator;
    log_enabled = true;
    editor = try edi.Editor.init(allocator);
    term = ter.Terminal{
        .writer = .{ .unbuffered_writer = std.io.null_writer.any() },
        .dimensions = .{ .width = 50, .height = 30 },
    };
}
