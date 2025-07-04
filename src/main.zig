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
const fzf = @import("ui/fzf.zig");
const env = @import("env.zig");

pub const Args = struct {
    path: ?[]u8 = null,
    log: bool = false,
    printer: bool = false,
    highlight_line: ?usize = null,
    term_height: ?usize = null,
};

pub const sleep_ns = 16 * 1e6;
pub const std_in = std.io.getStdIn();
pub const std_out = std.io.getStdOut();
pub const std_err = std.io.getStdErr();
pub var tty_in: std.fs.File = undefined;

pub var editor: edi.Editor = undefined;
pub var term: ter.Terminal = undefined;

pub var log_enabled = true;
pub var args: Args = .{};
pub var key_queue: std.ArrayList(inp.Key) = undefined;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.c_allocator;

    tty_in = try std.fs.cwd().openFile("/dev/tty", .{});

    var cmd_args = std.process.args();
    _ = cmd_args.skip();
    while (cmd_args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-v")) {
            args.log = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--printer")) {
            args.printer = true;
            continue;
        } else if (std.mem.startsWith(u8, arg, "--highlight-line=")) {
            const val = arg[17..];
            const val_exp = try env.expand(allocator, val, std.posix.getenv);
            args.highlight_line = try std.fmt.parseInt(usize, val_exp, 10) - 1;
            continue;
        } else if (std.mem.startsWith(u8, arg, "--term-height=")) {
            const val = arg[14..];
            const val_exp = try env.expand(allocator, val, std.posix.getenv);
            args.term_height = try std.fmt.parseInt(usize, val_exp, 10);
            continue;
        }
        args.path = @constCast(arg);
    }
    log_enabled = args.log;
    log.log(@This(), "logging enabled\n", .{});

    if (args.printer) {
        const path = args.path orelse return error.NoPath;
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(file_content);
        var buffer = try buf.Buffer.init(allocator, path, file_content);
        defer buffer.deinit();
        try buffer.tsParse();
        try buffer.updateLinePositions();
        try ter.printBuffer(
            &buffer,
            std_out.writer().any(),
            try ter.HighlightConfig.fromArgs(args),
        );
        return;
    } else {
        term = try ter.Terminal.init(std_out.writer().any(), try ter.terminalSize());
        defer term.deinit();

        editor = try edi.Editor.init(allocator);
        defer editor.deinit();

        const path = if (args.path) |path| try allocator.dupe(u8, path) else fzf.pickFile(allocator) catch return;
        defer allocator.free(path);

        try editor.openBuffer(path);
        try startEditor(allocator);
        defer editor.disconnect() catch {};
    }
}

fn startEditor(allocator: std.mem.Allocator) !void {
    key_queue = std.ArrayList(inp.Key).init(allocator);
    defer {
        for (key_queue.items) |key| if (key.printable) |p| allocator.free(p);
        key_queue.deinit();
    }

    var buffer = editor.activeBuffer();

    main_loop: while (true) {
        try editor.update();

        const needs_handle_mappings = try term.updateInput(allocator);
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
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 }));
                } else if (code == .down) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 }));
                } else if (code == .left) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = -1 }));
                } else if (code == .right) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = 1 }));
                } else if (code == .escape) {
                    try buffer.enterMode(.normal);

                    // normal or select mode
                } else if (normal_or_select and ch == 'q') {
                    break :main_loop;
                } else if (normal_or_select and ch == 'i') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 }));
                } else if (normal_or_select and ch == 'k') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 }));
                } else if (normal_or_select and ch == 'j') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = -1 }));
                } else if (normal_or_select and ch == 'l') {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = 1 }));
                } else if (normal_or_select and ch == 'w') {
                    try buffer.moveToNextWord();
                } else if (normal_or_select and ch == 'W') {
                    try buffer.moveToPrevWord();
                } else if (normal_or_select and ch == 'e') {
                    try buffer.moveToWordEnd();
                } else if (normal_or_select and ch == 'E') {
                    try buffer.moveToTokenEnd();
                } else if (normal_or_select and ch == 'd') {
                    try buffer.changeSelectionDelete();

                    // normal mode
                } else if (editor.mode == .normal and ch == 's') {
                    try buffer.enterMode(.select);
                } else if (editor.mode == .normal and ch == 'S') {
                    try buffer.enterMode(.select_line);
                } else if (editor.mode == .normal and ch == 'h') {
                    try buffer.enterMode(.insert);
                } else if (editor.mode == .normal and ch == 'o') {
                    try buffer.changeInsertLineBelow(@intCast(buffer.cursor.row));
                    try buffer.enterMode(.insert);
                } else if (editor.mode == .normal and ch == 'O') {
                    try buffer.changeInsertLineBelow(@intCast(buffer.cursor.row - 1));
                    try buffer.enterMode(.insert);
                } else if (editor.mode == .normal and ch == 'u') {
                    try buffer.undo();
                } else if (editor.mode == .normal and ch == 'U') {
                    try buffer.redo();
                } else if (editor.mode == .normal and ch == 'n' and key.activeModifier(.control)) {
                    try editor.pickFile();
                    buffer = editor.activeBuffer();
                } else if (editor.mode == .normal and ch == 'f' and key.activeModifier(.control)) {
                    try editor.findInFiles();
                    buffer = editor.activeBuffer();

                    // insert mode
                } else if (editor.mode == .insert and code == .delete) {
                    try buffer.changeDeleteChar();
                } else if (editor.mode == .insert and code == .backspace) {
                    try buffer.changeDeletePrevChar();
                } else if (editor.mode == .insert and key.printable != null) {
                    var printable = std.ArrayList(u21).init(allocator);
                    {
                        const utf = try uni.utf8FromBytes(allocator, key.printable.?);
                        defer allocator.free(utf);
                        try printable.appendSlice(utf);
                    }
                    // read more printable keys in case this is a paste command
                    while (true) {
                        const next_key = if (key_queue.items.len == 0) null else key_queue.items[0];
                        if (next_key != null and next_key.?.printable != null) {
                            _ = key_queue.orderedRemove(0);
                            const p = next_key.?.printable.?;
                            defer allocator.free(p);
                            const utf = try uni.utf8FromBytes(allocator, p);
                            defer allocator.free(utf);
                            try printable.appendSlice(utf);
                        } else {
                            break;
                        }
                    }
                    const insert_text = try printable.toOwnedSlice();
                    defer allocator.free(insert_text);
                    try buffer.changeInsertText(insert_text);
                    editor.needs_completion = true;

                    // multiple-key
                } else if (multiple_key) {
                    const key2 = key_queue.orderedRemove(0);
                    defer if (key2.printable) |p| allocator.free(p);
                    var ch2: ?u8 = null;
                    if (key2.printable != null and key2.printable.?.len == 1) ch2 = key2.printable.?[0];

                    if (editor.mode == .normal and ch == ' ' and ch2 == 'd') {
                        try buffer.goToDefinition();
                    } else if (normal_or_select and ch == 'g' and ch2 == 'i') {
                        try buffer.moveCursor(.{ .col = buffer.cursor.col });
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

        editor.needs_redraw = editor.needs_redraw or buffer.pending_changes.items.len > 0;
        if (buffer.pending_changes.items.len > 0) {
            buffer.diagnostics.clearRetainingCapacity();
            try buffer.tsParse();
            try buffer.updateLinePositions();
            var lsp_iter = editor.lsp_connections.valueIterator();
            while (lsp_iter.next()) |conn| {
                try conn.didChange(editor.activeBuffer());
                // TODO: send to correct server
                break;
            }
            for (buffer.pending_changes.items) |*change| change.deinit();
            buffer.pending_changes.clearRetainingCapacity();
            buffer.version += 1;
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
            var lsp_iter = editor.lsp_connections.valueIterator();
            while (lsp_iter.next()) |conn| {
                try conn.sendCompletionRequest();
                // TODO: send to correct server
                break;
            }
        }
        std.time.sleep(sleep_ns);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}

pub fn testSetup() !void {
    log_enabled = true;
    editor = try edi.Editor.init(std.testing.allocator);
    term = ter.Terminal{
        .writer = .{ .unbuffered_writer = std.io.null_writer.any() },
        .dimensions = .{ .width = 50, .height = 30 },
    };
}
