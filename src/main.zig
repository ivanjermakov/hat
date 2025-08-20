const std = @import("std");
const dl = std.DynLib;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");

const buf = @import("buffer.zig");
const co = @import("color.zig");
const core = @import("core.zig");
const edi = @import("editor.zig");
const env = @import("env.zig");
const ft = @import("file_type.zig");
const inp = @import("input.zig");
const log = @import("log.zig");
const lsp = @import("lsp.zig");
const pri = @import("printer.zig");
const sig = @import("signal.zig");
const ter = @import("terminal.zig");
const fzf = @import("ui/fzf.zig");
const uni = @import("unicode.zig");

pub const Args = struct {
    path: ?[]const u8 = null,
    log: bool = false,
    printer: bool = false,
    highlight_line: ?usize = null,
    term_height: ?usize = null,
};

pub const sleep_ns: u64 = 16 * 1e6;
pub const sleep_lsp_ns: u64 = sleep_ns;
pub const std_in = std.io.getStdIn();
pub const std_out = std.io.getStdOut();
pub const std_err = std.io.getStdErr();
pub var tty_in: std.fs.File = undefined;

pub var editor: edi.Editor = undefined;
pub var term: ter.Terminal = undefined;

pub var args: Args = .{};

pub var main_loop_mutex: std.Thread.Mutex = .{};

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
    log.enabled = args.log;
    log.info(@This(), "logging enabled\n", .{});

    if (args.printer) {
        const path = args.path orelse return error.NoPath;
        const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        const file_content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
        defer allocator.free(file_content);
        var buffer = try buf.Buffer.init(allocator, path, file_content);
        defer buffer.deinit();
        try pri.printBuffer(
            &buffer,
            std_out.writer().any(),
            try pri.HighlightConfig.fromArgs(args),
        );
        return;
    }

    term = try ter.Terminal.init(allocator, std_out.writer().any(), try ter.terminalSize());
    defer term.deinit();

    editor = try edi.Editor.init(allocator, .{});
    defer editor.deinit();

    const path = if (args.path) |path| try allocator.dupe(u8, path) else fzf.pickFile(allocator) catch return;
    defer allocator.free(path);

    try editor.openBuffer(path);
    try startEditor(allocator);
    defer editor.disconnect() catch {};
}

fn startEditor(allocator: Allocator) !void {
    var timer = try std.time.Timer.start();
    var timer_total = try std.time.Timer.start();
    var perf = std.mem.zeroes(PerfInfo);
    var buffer = editor.active_buffer;
    var repeat_count: ?usize = null;

    main_loop: while (true) {
        main_loop_mutex.lock();
        defer {
            main_loop_mutex.unlock();
            if (sleep_ns > perf.total) {
                std.time.sleep(sleep_ns - perf.total);
            }
        }

        _ = timer.lap();
        _ = timer_total.lap();

        try editor.updateInput();
        perf.input = timer.lap();

        const eql = std.mem.eql;
        buffer = editor.active_buffer;
        if (editor.dirty.input) {
            editor.dirty.input = false;
            editor.dotRepeatExecuted();
            while (editor.key_queue.items.len > 0) {
                const raw_key = editor.key_queue.items[0];
                const key = try std.fmt.allocPrint(allocator, "{}", .{raw_key});
                defer allocator.free(key);

                const normal_or_select = editor.mode.normalOrSelect();

                if (normal_or_select and key.len == 1 and std.ascii.isDigit(key[0])) {
                    const d = std.fmt.parseInt(usize, key, 10) catch unreachable;
                    repeat_count = (if (repeat_count) |rc| rc * 10 else 0) + d;
                    const removed = editor.key_queue.orderedRemove(0);
                    try editor.recordMacroKey(removed);
                    removed.deinit();
                }

                var keys_consumed: usize = 1;
                switch (editor.mode) {
                    .normal => editor.dotRepeatOutside(),
                    else => editor.dotRepeatInside(),
                }
                const multiple_key = editor.key_queue.items.len > 1;
                const cmp_menu_active = editor.mode == .insert and
                    editor.completion_menu.display_items.items.len > 0;
                const cmd_active = editor.command_line.command != null;
                var repeat_or_1: i32 = 1;
                if (repeat_count) |rc| repeat_or_1 = @intCast(rc);

                // command line menu
                if (cmd_active) {
                    if (eql(u8, key, "\n")) {
                        try editor.handleCmd();
                    } else if (cmd_active and eql(u8, key, "<escape>")) {
                        editor.command_line.close();
                    } else if (cmd_active and eql(u8, key, "<left>")) {
                        editor.command_line.left();
                    } else if (cmd_active and eql(u8, key, "<right>")) {
                        editor.command_line.right();
                    } else if (cmd_active and eql(u8, key, "<backspace>")) {
                        editor.command_line.backspace();
                    } else if (cmd_active and eql(u8, key, "<delete>")) {
                        editor.command_line.delete();
                    } else if (cmd_active and raw_key.printable != null) {
                        try editor.command_line.insert(raw_key.printable.?);
                    }

                    // text insertion
                } else if (editor.mode == .insert and editor.key_queue.items[0].printable != null) {
                    var printable = std.ArrayList(u21).init(allocator);
                    keys_consumed = 0;
                    // read all cosecutive printable keys in case this is a paste command
                    while (true) {
                        const next_key = if (keys_consumed < editor.key_queue.items.len) editor.key_queue.items[keys_consumed] else null;
                        if (next_key != null and next_key.?.printable != null) {
                            try printable.appendSlice(next_key.?.printable.?);
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
                    editor.completion_menu.prevItem();
                } else if (cmp_menu_active and eql(u8, key, "<down>")) {
                    editor.completion_menu.nextItem();
                } else if (cmp_menu_active and eql(u8, key, "\n")) {
                    try editor.completion_menu.accept();

                    // global
                } else if (eql(u8, key, "<up>")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 }));
                } else if (eql(u8, key, "<down>")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 }));
                } else if (eql(u8, key, "<left>")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = -1 }));
                } else if (eql(u8, key, "<right>")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = 1 }));
                } else if (eql(u8, key, "<escape>")) {
                    try editor.enterMode(.normal);
                    editor.dismissMessage();
                    repeat_count = null;

                    // normal mode with modifiers
                } else if (editor.mode == .normal and eql(u8, key, "<c-n>")) {
                    try editor.pickFile();
                } else if (editor.mode == .normal and eql(u8, key, "<c-f>")) {
                    try editor.findInFiles();
                } else if (editor.mode == .normal and eql(u8, key, "<c-e>")) {
                    try editor.pickBuffer();
                } else if (editor.mode == .normal and eql(u8, key, "<c-d>")) {
                    if (editor.hover_contents) |hover| {
                        try editor.openScratch(hover);
                    } else {
                        try buffer.showHover();
                    }

                    // normal or select mode
                } else if (normal_or_select and eql(u8, key, "k")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 * repeat_or_1 }));
                } else if (normal_or_select and eql(u8, key, "j")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = 1 * repeat_or_1 }));
                } else if (normal_or_select and eql(u8, key, "h")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = -1 * repeat_or_1 }));
                } else if (normal_or_select and eql(u8, key, "l")) {
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .col = 1 * repeat_or_1 }));
                } else if (normal_or_select and eql(u8, key, "<c-u>")) {
                    const half_screen = @divFloor(@as(i32, @intCast(term.dimensions.height)), 2);
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = -1 * repeat_or_1 * half_screen }));
                    buffer.centerCursor();
                } else if (normal_or_select and eql(u8, key, "<c-d>")) {
                    const half_screen = @divFloor(@as(i32, @intCast(term.dimensions.height)), 2);
                    buffer.moveCursor(buffer.cursor.applyOffset(.{ .row = repeat_or_1 * half_screen }));
                    buffer.centerCursor();
                } else if (normal_or_select and eql(u8, key, "w")) {
                    buffer.moveToNextWord();
                } else if (normal_or_select and eql(u8, key, "W")) {
                    buffer.moveToPrevWord();
                } else if (normal_or_select and eql(u8, key, "e")) {
                    buffer.moveToWordEnd();
                } else if (normal_or_select and eql(u8, key, "E")) {
                    buffer.moveToTokenEnd();
                } else if (normal_or_select and eql(u8, key, "i")) {
                    try editor.enterMode(.insert);
                } else if (normal_or_select and eql(u8, key, "c")) {
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
                    buffer.centerCursor();
                } else if (normal_or_select and eql(u8, key, ":")) {
                    buffer.pipePrompt();

                    // normal mode
                } else if (normal_or_select and (eql(u8, key, "q") or eql(u8, key, "Q"))) {
                    const force = eql(u8, key, "Q");
                    try editor.closeBuffer(force);
                    if (editor.buffers.items.len == 0) break :main_loop;
                } else if (editor.mode == .normal and eql(u8, key, "v")) {
                    try editor.enterMode(.select);
                } else if (editor.mode == .normal and eql(u8, key, "V")) {
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
                    editor.command_line.activate(.find);
                } else if (editor.mode == .normal and eql(u8, key, "n")) {
                    if (editor.find_query) |q| try buffer.findNext(q, true);
                } else if (editor.mode == .normal and eql(u8, key, "N")) {
                    if (editor.find_query) |q| try buffer.findNext(q, false);
                } else if (editor.mode == .normal and eql(u8, key, "x")) {
                    try buffer.findNextDiagnostic(true);
                } else if (editor.mode == .normal and eql(u8, key, "X")) {
                    try buffer.findNextDiagnostic(false);
                } else if (editor.mode == .normal and eql(u8, key, "r") and editor.recording_macro != null) {
                    try editor.recordMacro();

                    // insert mode
                } else if (editor.mode == .insert and eql(u8, key, "<delete>")) {
                    try buffer.changeDeleteChar();
                } else if (editor.mode == .insert and eql(u8, key, "<backspace>")) {
                    try buffer.changeDeletePrevChar();
                } else if (multiple_key) {
                    keys_consumed = 2;
                    const key2 = editor.key_queue.items[1];
                    // no need for more than 2 keys for now
                    const multi_key = try std.fmt.allocPrint(allocator, "{s}{}", .{ key, key2 });
                    defer allocator.free(multi_key);

                    if (editor.mode == .normal and eql(u8, multi_key, " w")) {
                        try buffer.write();
                    } else if (editor.mode == .normal and eql(u8, multi_key, " d")) {
                        try buffer.goToDefinition();
                    } else if (editor.mode == .normal and eql(u8, multi_key, " r")) {
                        try buffer.findReferences();
                    } else if (editor.mode == .normal and eql(u8, multi_key, " n")) {
                        try buffer.renamePrompt();
                    } else if (editor.mode == .normal and eql(u8, key, "r") and editor.key_queue.items[1].printable != null) {
                        const macro_name: u8 = @intCast(key2.printable.?[0]);
                        try editor.startMacro(macro_name);
                    } else if (editor.mode == .normal and eql(u8, key, "@") and editor.key_queue.items[1].printable != null) {
                        const macro_name: u8 = @intCast(key2.printable.?[0]);
                        try editor.replayMacro(macro_name);
                    } else if (normal_or_select and eql(u8, multi_key, "gk")) {
                        buffer.moveCursor(.{ .col = buffer.cursor.col });
                        buffer.centerCursor();
                    } else if (normal_or_select and eql(u8, multi_key, "gj")) {
                        buffer.moveCursor(.{
                            .row = @as(i32, @intCast(buffer.line_positions.items.len)) - 1,
                            .col = buffer.cursor.col,
                        });
                        buffer.centerCursor();
                    } else if (normal_or_select and eql(u8, multi_key, "gl")) {
                        buffer.moveCursor(.{
                            .row = buffer.cursor.row,
                            .col = @intCast(buffer.lineLength(@intCast(buffer.cursor.row))),
                        });
                    } else if (normal_or_select and eql(u8, multi_key, "gh")) {
                        buffer.moveCursor(.{ .row = buffer.cursor.row, .col = 0 });
                    } else {
                        // no multi-key matches, drop first key as it will never match
                        keys_consumed = 1;
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
                    try editor.recordMacroKey(removed);
                    removed.deinit();
                    repeat_count = null;
                }
                // log.debug(@This(), "uncommitted: {any}\n", .{editor.dot_repeat_input_uncommitted.items});
                // log.debug(@This(), "committed: {any}\n", .{editor.dot_repeat_input.items});
            }
        }
        perf.mapping = timer.lap();

        buffer = editor.active_buffer;
        editor.dirty.draw = editor.dirty.draw or buffer.pending_changes.items.len > 0;
        if (buffer.pending_changes.items.len > 0) {
            buffer.version += 1;
            buffer.clearDiagnostics();
            try buffer.reparse();
            perf.parse = timer.lap();
            for (buffer.lsp_connections.items) |conn| {
                try conn.didChange(editor.active_buffer);
            }
            for (buffer.pending_changes.items) |*change| change.deinit();
            buffer.pending_changes.clearRetainingCapacity();
            perf.did_change = timer.lap();
        } else {
            perf.parse = 0;
            perf.did_change = 0;
        }

        if (editor.dirty.draw) {
            editor.dirty.draw = false;
            try term.draw();
        } else if (editor.dirty.cursor) {
            editor.dirty.cursor = false;
            try term.updateCursor();
        }
        perf.draw = timer.lap();

        if (editor.dirty.completion) {
            editor.dirty.completion = false;
            for (buffer.lsp_connections.items) |conn| {
                try conn.sendCompletionRequest();
            }
        }
        if (editor.dot_repeat_state == .commit_ready) {
            try editor.dotRepeatCommit();
        }
        perf.commit = timer.lap();

        if (try buffer.syncFs()) {
            try editor.sendMessage("external buffer modification");
            try buffer.changeFsExternal();
        }
        perf.sync = timer.lap();

        perf.total = timer_total.lap();
        if (perf.total > 10 * std.time.ns_per_ms) {
            log.debug(@This(), "frame perf: \n{}", .{perf});
        }
    }
}

const PerfInfo = struct {
    input: u64,
    mapping: u64,
    parse: u64,
    did_change: u64,
    draw: u64,
    commit: u64,
    sync: u64,
    total: u64,

    pub fn format(
        self: *const PerfInfo,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try std.fmt.format(
            writer,
            "total: {}, input: {}, parse: {}, mapping: {}, did_change: {}, draw: {}, commit: {}, sync: {}\n",
            .{
                self.total / std.time.ns_per_us,
                self.input / std.time.ns_per_us,
                self.parse / std.time.ns_per_us,
                self.mapping / std.time.ns_per_us,
                self.did_change / std.time.ns_per_us,
                self.draw / std.time.ns_per_us,
                self.commit / std.time.ns_per_us,
                self.sync / std.time.ns_per_us,
            },
        );
    }
};

comptime {
    std.testing.refAllDecls(@This());
}

pub fn testSetup() !void {
    const allocator = std.testing.allocator;
    log.enabled = true;
    editor = try edi.Editor.init(allocator, .{});
    term = ter.Terminal{
        .writer = .{ .unbuffered_writer = std.io.null_writer.any() },
        .dimensions = .{ .width = 50, .height = 30 },
        .allocator = allocator,
    };
}
