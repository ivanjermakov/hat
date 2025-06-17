const std = @import("std");
const builtin = @import("builtin");
const dl = std.DynLib;
const c = @cImport({
    @cInclude("ncurses.h");
});
const act = @import("action.zig");
const inp = @import("input.zig");
const uni = @import("unicode.zig");
const ft = @import("file_type.zig");
const buf = @import("buffer.zig");
const co = @import("color.zig");
const te = @import("term.zig");
const lsp = @import("lsp.zig");
const log = @import("log.zig");

pub const Cursor = struct {
    row: i32,
    col: i32,
};

const Mode = enum {
    normal,
    select,
    insert,

    pub fn normal_or_select(self: Mode) bool {
        return self == .normal or self == .select;
    }
};

const Args = struct {
    path: ?[]u8,
    log: bool,
};

pub const sleep_ns = 16 * 1e6;
pub var allocator: std.mem.Allocator = undefined;
pub const std_out = std.io.getStdOut();

pub var buffer: buf.Buffer = undefined;
pub var cursor: Cursor = .{ .row = 0, .col = 0 };
pub var mode: Mode = .normal;
pub var needs_redraw = false;
pub var needs_reparse = false;
pub var log_enabled = true;
pub var args: Args = .{
    .path = null,
    .log = false,
};
pub var key_queue: std.ArrayList(inp.Key) = undefined;

fn redraw() !void {
    _ = c.erase();

    var byte: usize = 0;
    for (0..buffer.content.items.len) |row| {
        const line: []u8 = buffer.content.items[row].items;
        const line_view = try std.unicode.Utf8View.init(line);
        var line_iter = line_view.iterator();

        var col: usize = 0;
        while (line_iter.nextCodepoint()) |ch| {
            var ch_attr = co.Attr.text;
            for (buffer.spans.items) |span| {
                if (span.span.start_byte <= byte and span.span.end_byte > byte) {
                    if (std.mem.eql(u8, span.node_type, "return") or
                        std.mem.eql(u8, span.node_type, "primitive_type") or
                        std.mem.eql(u8, span.node_type, "#include") or
                        std.mem.eql(u8, span.node_type, "export") or
                        std.mem.eql(u8, span.node_type, "function"))
                    {
                        ch_attr = co.Attr.keyword;
                        break;
                    }
                    if (std.mem.eql(u8, span.node_type, "system_lib_string") or
                        std.mem.eql(u8, span.node_type, "string_literal") or
                        std.mem.eql(u8, span.node_type, "string"))
                    {
                        ch_attr = co.Attr.string;
                        break;
                    }
                    if (std.mem.eql(u8, span.node_type, "number_literal")) {
                        ch_attr = co.Attr.number;
                        break;
                    }
                }
            }
            _ = c.attrset(@intFromEnum(ch_attr));
            if (mode == .select) {
                if (buffer.selection.?.in_range(.{ .line = row, .character = col })) {
                    _ = c.attrset(@intFromEnum(co.Attr.selection));
                }
            }
            const cchar = uni.codepoint_to_cchar(ch);
            _ = c.mvadd_wch(@intCast(row), @intCast(col), @ptrCast(&cchar));
            byte += try std.unicode.utf8CodepointSequenceLength(ch);
            col += 1;
        }
        byte += 1;
    }

    _ = c.standend();
    _ = c.move(@intCast(cursor.row), @intCast(cursor.col));

    switch (mode) {
        .normal, .select => _ = try std_out.write(inp.cursor_type.steady_block),
        .insert => _ = try std_out.write(inp.cursor_type.steady_bar),
    }
}

pub fn main() !void {
    defer deinit();

    var debug_allocator: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;
    defer _ = debug_allocator.deinit();
    allocator = if (builtin.mode == .Debug) debug_allocator.allocator() else std.heap.c_allocator;

    try ft.init_file_types(allocator);
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

    buffer = try buf.Buffer.init(allocator, path, file_content);
    defer buffer.deinit();
    try buffer.ts_parse();

    try te.setup_terminal();
    const win = try te.init_curses();
    _ = win;

    try redraw();

    const lsp_conf = lsp.LspConfig{ .cmd = &[_][]const u8{ "typescript-language-server", "--stdio" } };
    var lsp_conn = try lsp.LspConnection.connect(allocator, &lsp_conf);
    defer lsp_conn.deinit();

    main_loop: while (true) {
        _ = c.refresh();
        std.time.sleep(sleep_ns);

        try lsp_conn.update();

        var needs_handle_mappings = false;
        if (try inp.get_codes(allocator)) |codes| {
            defer allocator.free(codes);
            needs_handle_mappings = true;
            const new_keys = try inp.get_keys(allocator, codes);
            defer allocator.free(new_keys);
            try key_queue.appendSlice(new_keys);
        }

        if (needs_handle_mappings) {
            log.log(@This(), "key_queue: {any}\n", .{key_queue.items});
            handle_mappings: while (key_queue.items.len > 0) {
                // log.log(@This(), "keys: {any}\n", .{keys.items});
                const key = key_queue.orderedRemove(0);
                defer if (key.printable) |p| allocator.free(p);

                const code = key.code;
                var ch: ?u8 = null;
                if (key.printable != null and key.printable.?.len == 1) ch = key.printable.?[0];

                const multiple_key = key_queue.items.len > 0;
                const normal_or_select = mode.normal_or_select();

                // TODO: crazy comptime

                // single-key global
                if (code == .up) {
                    act.move_cursor(.{ .row = cursor.row - 1, .col = cursor.col });
                } else if (code == .down) {
                    act.move_cursor(.{ .row = cursor.row + 1, .col = cursor.col });
                } else if (code == .left) {
                    act.move_cursor(.{ .row = cursor.row, .col = cursor.col - 1 });
                } else if (code == .right) {
                    act.move_cursor(.{ .row = cursor.row, .col = cursor.col + 1 });
                } else if (code == .escape) {
                    mode = .normal;
                    needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{mode});

                    // single-key normal or select mode
                } else if (normal_or_select and ch == 'q') {
                    break :main_loop;
                } else if (normal_or_select and ch == 'i') {
                    act.move_cursor(.{ .row = cursor.row - 1, .col = cursor.col });
                } else if (normal_or_select and ch == 'k') {
                    act.move_cursor(.{ .row = cursor.row + 1, .col = cursor.col });
                } else if (normal_or_select and ch == 'j') {
                    act.move_cursor(.{ .row = cursor.row, .col = cursor.col - 1 });
                } else if (normal_or_select and ch == 'l') {
                    act.move_cursor(.{ .row = cursor.row, .col = cursor.col + 1 });

                    // single-key normal mode
                } else if (mode == .normal and ch == 's') {
                    mode = .select;
                    try act.select_char();
                    needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{mode});
                } else if (mode == .normal and ch == 'h') {
                    mode = .insert;
                    needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{mode});

                    // single-key insert mode
                } else if (mode == .insert and code == .delete) {
                    try act.remove_char();
                } else if (mode == .insert and code == .backspace) {
                    try act.remove_prev_char();
                } else if (mode == .insert and code == .enter) {
                    try act.insert_newline();
                } else if (mode == .insert and key.printable != null) {
                    try act.insert_text(key.printable.?);
                } else if (multiple_key and mode == .normal and ch == ' ') {
                    // multiple-key normal mode
                    const key2 = key_queue.orderedRemove(0);
                    defer if (key2.printable) |p| allocator.free(p);
                    var ch2: ?u8 = null;
                    if (key2.printable != null and key2.printable.?.len == 1) ch2 = key2.printable.?[0];

                    if (ch2 == 'd') {
                        try lsp_conn.go_to_definition();
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

        needs_redraw = needs_redraw or needs_reparse;
        if (needs_reparse) {
            needs_reparse = false;
            try buffer.ts_parse();
            try lsp_conn.did_change();
        }
        if (needs_redraw) {
            needs_redraw = false;
            try redraw();
        }
    }

    log.log(@This(), "disconnecting lsp client\n", .{});
    try lsp_conn.disconnect();
    disconnect_loop: while (true) {
        if (lsp_conn.status == .Closed) break :disconnect_loop;
        try lsp_conn.update();
    }
}

fn deinit() void {
    _ = c.endwin();
    _ = std_out.write(inp.cursor_type.steady_block) catch {};
}

comptime {
    std.testing.refAllDecls(@This());
}
