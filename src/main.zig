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
const sig = @import("signal.zig");

pub const Args = struct {
    path: ?[]const u8 = null,
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

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.c_allocator;

    tty_in = try std.fs.cwd().openFile("/dev/tty", .{});

    sig.registerAll();

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
        try buffer.reparse();
        try ter.printBuffer(
            &buffer,
            std_out.writer().any(),
            try ter.HighlightConfig.fromArgs(args),
        );
        return;
    } else {
        term = try ter.Terminal.init(allocator, std_out.writer().any(), try ter.terminalSize());
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
    var buffer = editor.active_buffer;

    main_loop: while (true) {
        try editor.update();
        buffer = editor.active_buffer;

        try editor.updateInput();

        const eql = std.mem.eql;
        if (editor.dirty.input) {
            editor.dirty.input = false;
            editor.dotRepeatExecuted();
            while (editor.key_queue.items.len > 0) {
                var keys_consumed: usize = 1;
                switch (editor.mode) {
                    .normal => editor.dotRepeatOutside(),
                    else => editor.dotRepeatInside(),
                }
                const multiple_key = editor.key_queue.items.len > 1;
                const normal_or_select = editor.mode.normalOrSelect();
                const cmp_menu_active = editor.mode == .insert and
                    editor.completion_menu.display_items.items.len > 0;
                const cmd_active = editor.command_line.command != null;

                const key = try std.fmt.allocPrint(allocator, "{}", .{editor.key_queue.items[0]});
                defer allocator.free(key);

                // command line menu
                if (cmd_active and eql(u8, key, "\n")) {
                    try editor.handleCmd();
                } else if (cmd_active and eql(u8, key, "<escape>")) {
                    editor.command_line.close();
                } else if (cmd_active and editor.key_queue.items[0].printable != null) {
                    const key_uni = try uni.utf8FromBytes(allocator, key);
                    defer allocator.free(key_uni);
                    try editor.command_line.insert(key_uni);

                    // text insertion
                } else if (editor.mode == .insert and editor.key_queue.items[0].printable != null) {
                    var printable = std.ArrayList(u21).init(allocator);
                    keys_consumed = 0;
                    // read all cosecutive printable keys in case this is a paste command
                    while (true) {
                        const next_key = if (keys_consumed < editor.key_queue.items.len) editor.key_queue.items[keys_consumed] else null;
                        if (next_key != null and next_key.?.printable != null) {
                            const p = next_key.?.printable.?;
                            const utf = try uni.utf8FromBytes(allocator, p);
                            defer allocator.free(utf);
                            try printable.appendSlice(utf);
                            keys_consumed += 1;
                        } else {
                            break;
                        }
                    }
                    const insert_text = try printable.toOwnedSlice();
                    defer allocator.free(insert_text);
                    try buffer.changeInsertText(insert_text);
                    editor.dirty.completion = true;

                    // cmp_menu
                } else if (cmp_menu_active and eql(u8, key, "<up>")) {
                    try editor.completion_menu.prevItem();
                } else if (cmp_menu_active and eql(u8, key, "<down>")) {
                    try editor.completion_menu.nextItem();
                } else if (cmp_menu_active and eql(u8, key, "\n")) {
                    try editor.completion_menu.accept();

                    // global
                } else if (eql(u8, key, "<up>")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 }));
                } else if (eql(u8, key, "<down>")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 }));
                } else if (eql(u8, key, "<left>")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = -1 }));
                } else if (eql(u8, key, "<right>")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = 1 }));
                } else if (eql(u8, key, "<escape>")) {
                    try editor.enterMode(.normal);
                    try editor.dismissMessage();

                    // normal mode with modifiers
                } else if (editor.mode == .normal and eql(u8, key, "c-n")) {
                    try editor.pickFile();
                } else if (editor.mode == .normal and eql(u8, key, "c-f")) {
                    try editor.findInFiles();
                } else if (editor.mode == .normal and eql(u8, key, "<c-e>")) {
                    try editor.pickBuffer();
                } else if (editor.mode == .normal and eql(u8, key, "<c-d>")) {
                    try buffer.showHover();

                    // normal or select mode
                } else if (normal_or_select and eql(u8, key, "i")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 }));
                } else if (normal_or_select and eql(u8, key, "k")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 }));
                } else if (normal_or_select and eql(u8, key, "j")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = -1 }));
                } else if (normal_or_select and eql(u8, key, "l")) {
                    try buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = 1 }));
                } else if (normal_or_select and eql(u8, key, "I")) {
                    for (0..@divFloor(term.dimensions.height, 2)) |_| {
                        try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 }));
                    }
                    try buffer.centerCursor();
                } else if (normal_or_select and eql(u8, key, "K")) {
                    for (0..@divFloor(term.dimensions.height, 2)) |_| {
                        try buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 }));
                    }
                    try buffer.centerCursor();
                } else if (normal_or_select and eql(u8, key, "w")) {
                    try buffer.moveToNextWord();
                } else if (normal_or_select and eql(u8, key, "W")) {
                    try buffer.moveToPrevWord();
                } else if (normal_or_select and eql(u8, key, "e")) {
                    try buffer.moveToWordEnd();
                } else if (normal_or_select and eql(u8, key, "E")) {
                    try buffer.moveToTokenEnd();
                } else if (normal_or_select and eql(u8, key, "h")) {
                    try buffer.changeSelectionDelete();
                    try editor.enterMode(.insert);
                } else if (normal_or_select and eql(u8, key, "d")) {
                    try buffer.changeSelectionDelete();
                    try buffer.commitChanges();
                } else if (normal_or_select and eql(u8, key, "=")) {
                    try buffer.changeAlignIndent();
                    try editor.enterMode(.normal);
                } else if (normal_or_select and eql(u8, key, "y")) {
                    try buffer.copySelectionToClipboard();
                } else if (normal_or_select and eql(u8, key, "p")) {
                    try buffer.changeInsertFromClipboard();
                } else if (normal_or_select and eql(u8, key, "z")) {
                    try buffer.centerCursor();

                    // normal mode
                } else if (normal_or_select and (eql(u8, key, "q") or eql(u8, key, "Q"))) {
                    const force = eql(u8, key, "Q");
                    try editor.closeBuffer(force);
                    if (editor.buffers.items.len == 0) break :main_loop;
                } else if (editor.mode == .normal and eql(u8, key, "s")) {
                    try editor.enterMode(.select);
                } else if (editor.mode == .normal and eql(u8, key, "S")) {
                    try editor.enterMode(.select_line);
                } else if (editor.mode == .normal and eql(u8, key, "o")) {
                    try buffer.changeInsertLineBelow(buffer.cursor.row);
                    try editor.enterMode(.insert);
                } else if (editor.mode == .normal and eql(u8, key, "O")) {
                    try buffer.changeInsertLineAbove(buffer.cursor.row);
                    try editor.enterMode(.insert);
                } else if (editor.mode == .normal and eql(u8, key, "u")) {
                    try buffer.undo();
                } else if (editor.mode == .normal and eql(u8, key, "U")) {
                    try buffer.redo();
                } else if (editor.mode == .normal and eql(u8, key, "<tab>")) {
                    if (editor.buffers.items.len > 1) {
                        try editor.openBuffer(editor.buffers.items[1].path);
                    }
                } else if (editor.mode == .normal and eql(u8, key, ".")) {
                    try editor.dotRepeat();
                } else if (editor.mode == .normal and eql(u8, key, "/")) {
                    try editor.command_line.activate(.find);
                } else if (editor.mode == .normal and eql(u8, key, "n")) {
                    if (editor.find_query) |q| try buffer.findNext(q, true);
                } else if (editor.mode == .normal and eql(u8, key, "N")) {
                    if (editor.find_query) |q| try buffer.findNext(q, false);

                    // insert mode
                } else if (editor.mode == .insert and eql(u8, key, "<delete>")) {
                    try buffer.changeDeleteChar();
                } else if (editor.mode == .insert and eql(u8, key, "<backspace>")) {
                    try buffer.changeDeletePrevChar();
                } else if (multiple_key) {
                    keys_consumed = 2;
                    // no need for more than 2 keys for now
                    const multi_key = try std.fmt.allocPrint(
                        allocator,
                        "{}{}",
                        .{ editor.key_queue.items[0], editor.key_queue.items[1] },
                    );
                    defer allocator.free(multi_key);

                    if (editor.mode == .normal and eql(u8, multi_key, " w")) {
                        try buffer.write();
                    } else if (editor.mode == .normal and eql(u8, multi_key, " d")) {
                        try buffer.goToDefinition();
                    } else if (normal_or_select and eql(u8, multi_key, "gi")) {
                        try buffer.moveCursor(.{ .col = buffer.cursor.col });
                        try buffer.centerCursor();
                    } else if (normal_or_select and eql(u8, multi_key, "gk")) {
                        try buffer.moveCursor(.{
                            .row = @as(i32, @intCast(buffer.line_positions.items.len)) - 1,
                            .col = buffer.cursor.col,
                        });
                        try buffer.centerCursor();
                    } else if (normal_or_select and eql(u8, multi_key, "gl")) {
                        try buffer.moveCursor(.{
                            .row = buffer.cursor.row,
                            .col = @intCast(buffer.lineLength(@intCast(buffer.cursor.row))),
                        });
                    } else if (normal_or_select and eql(u8, multi_key, "gj")) {
                        try buffer.moveCursor(.{ .row = buffer.cursor.row, .col = 0 });
                    } else {
                        // no multi-key matches, drop first key as it will never match and try again
                        const removed = editor.key_queue.orderedRemove(0);
                        if (removed.printable) |p| allocator.free(p);
                        continue;
                    }
                } else {
                    // no mapping matches, wait for more keys
                    keys_consumed = 0;
                    break;
                }
                for (0..keys_consumed) |_| {
                    switch (editor.dot_repeat_state) {
                        .inside, .commit_ready => try editor.dot_repeat_input_uncommitted.append(
                            try editor.key_queue.items[0].clone(editor.allocator),
                        ),
                        else => {},
                    }
                    const removed = editor.key_queue.orderedRemove(0);
                    if (removed.printable) |p| allocator.free(p);
                }
                // log.log(@This(), "uncommitted: {any}\n", .{editor.dot_repeat_input_uncommitted.items});
                // log.log(@This(), "committed: {any}\n", .{editor.dot_repeat_input.items});
            }
        }

        buffer = editor.active_buffer;
        editor.dirty.draw = editor.dirty.draw or buffer.pending_changes.items.len > 0;
        if (buffer.pending_changes.items.len > 0) {
            buffer.diagnostics.clearRetainingCapacity();
            try buffer.reparse();
            for (buffer.lsp_connections.items) |conn| {
                try conn.didChange(editor.active_buffer);
            }
            for (buffer.pending_changes.items) |*change| change.deinit();
            buffer.pending_changes.clearRetainingCapacity();
            buffer.version += 1;
        }
        if (editor.dirty.draw) {
            editor.dirty.draw = false;
            try term.draw();
        } else if (editor.dirty.cursor) {
            editor.dirty.cursor = false;
            try term.updateCursor();
        }
        if (editor.dirty.completion) {
            editor.dirty.completion = false;
            for (buffer.lsp_connections.items) |conn| {
                try conn.sendCompletionRequest();
            }
        }
        if (editor.dot_repeat_state == .commit_ready) {
            try editor.dotRepeatCommit();
        }
        if (try buffer.syncFs()) {
            try editor.sendMessage("external buffer modification");
            try buffer.changeFsExternal();
        }
        std.time.sleep(sleep_ns);
    }
}

comptime {
    std.testing.refAllDecls(@This());
}

pub fn testSetup() !void {
    const allocator = std.testing.allocator;
    log_enabled = true;
    editor = try edi.Editor.init(allocator);
    term = ter.Terminal{
        .writer = .{ .unbuffered_writer = std.io.null_writer.any() },
        .dimensions = .{ .width = 50, .height = 30 },
        .allocator = allocator,
    };
}
