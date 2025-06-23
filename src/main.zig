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

const Args = struct {
    path: ?[]u8,
    log: bool,
};

pub const sleep_ns = 16 * 1e6;
pub var allocator: std.mem.Allocator = undefined;
pub const std_out = std.io.getStdOut();
pub const std_in = std.io.getStdIn();

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

    try ft.initFileTypes(allocator);
    defer {
        var value_iter = ft.file_type.valueIterator();
        while (value_iter.next()) |v| {
            allocator.free(v.lib_path);
            allocator.free(v.lib_symbol);
        }
        ft.file_type.deinit();
    }

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
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_content);

    editor = try edi.Editor.init(allocator);
    defer editor.deinit();

    var buffer = try buf.Buffer.init(allocator, path, file_content);
    editor.needs_reparse = true;
    try editor.buffers.append(&buffer);
    editor.active_buffer = &buffer;

    term = try ter.Terminal.init(std_out.writer().any());
    defer term.deinit();

    const lsp_conf = lsp.LspConfig{ .cmd = &[_][]const u8{ "typescript-language-server", "--stdio" } };
    var lsp_conn = try lsp.LspConnection.connect(allocator, &lsp_conf);
    defer lsp_conn.deinit();

    main_loop: while (true) {
        try lsp_conn.update();

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

                // TODO: crazy comptime

                // single-key global
                if (code == .up) {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row - 1, .col = buffer.cursor.col });
                } else if (code == .down) {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row + 1, .col = buffer.cursor.col });
                } else if (code == .left) {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = buffer.cursor.col - 1 });
                } else if (code == .right) {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = buffer.cursor.col + 1 });
                } else if (code == .escape) {
                    editor.mode = .normal;
                    editor.needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{editor.mode});

                    // single-key normal or select mode
                } else if (normal_or_select and ch == 'q') {
                    break :main_loop;
                } else if (normal_or_select and ch == 'i') {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row - 1, .col = buffer.cursor.col });
                } else if (normal_or_select and ch == 'k') {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row + 1, .col = buffer.cursor.col });
                } else if (normal_or_select and ch == 'j') {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = buffer.cursor.col - 1 });
                } else if (normal_or_select and ch == 'l') {
                    try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = buffer.cursor.col + 1 });

                    // single-key normal mode
                } else if (editor.mode == .normal and ch == 's') {
                    editor.mode = .select;
                    try buffer.selectChar();
                    editor.needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{editor.mode});
                } else if (editor.mode == .normal and ch == 'h') {
                    editor.mode = .insert;
                    editor.needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{editor.mode});

                    // single-key insert mode
                } else if (editor.mode == .insert and code == .delete) {
                    try buffer.removeChar();
                } else if (editor.mode == .insert and code == .backspace) {
                    try buffer.removePrevChar();
                } else if (editor.mode == .insert and code == .enter) {
                    try buffer.insertNewline();
                } else if (editor.mode == .insert and key.printable != null) {
                    try buffer.insertText(key.printable.?);
                } else if (multiple_key and editor.mode == .normal and ch == ' ') {
                    // multiple-key normal mode
                    const key2 = key_queue.orderedRemove(0);
                    defer if (key2.printable) |p| allocator.free(p);
                    var ch2: ?u8 = null;
                    if (key2.printable != null and key2.printable.?.len == 1) ch2 = key2.printable.?[0];

                    if (ch2 == 'd') {
                        try lsp_conn.goToDefinition();
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
            try lsp_conn.didChange();
        }
        if (editor.needs_redraw) {
            editor.needs_redraw = false;
            try term.draw();
        }
        std.time.sleep(sleep_ns);
    }

    log.log(@This(), "disconnecting lsp client\n", .{});
    try lsp_conn.disconnect();
    disconnect_loop: while (true) {
        if (lsp_conn.status == .Closed) break :disconnect_loop;
        try lsp_conn.update();
    }
}

comptime {
    std.testing.refAllDecls(@This());
}

pub fn testingSetup() !void {
    const alloc = std.testing.allocator;
    term = ter.Terminal{ .writer = .{ .unbuffered_writer = std.io.null_writer.any() } };
    ft.file_type = std.StringHashMap(ft.FileType).init(alloc);
}
