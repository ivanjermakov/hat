const std = @import("std");
const builtin = @import("builtin");
const dl = std.DynLib;
const inp = @import("input.zig");
const ft = @import("file_type.zig");
const buf = @import("buffer.zig");
const co = @import("color.zig");
const ter = @import("term.zig");
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
pub const std_in = std.io.getStdIn();

pub var buffer: buf.Buffer = undefined;
pub var term: ter.Term = undefined;
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
    var attrs_buf = std.mem.zeroes([128]u8);
    var attrs_stream = std.io.fixedBufferStream(&attrs_buf);
    var attrs: []const u8 = undefined;
    var last_attrs_buf = std.mem.zeroes([128]u8);
    var last_attrs: ?[]const u8 = null;

    try term.clear();
    const dims = try term.terminal_size();

    var byte: usize = 0;
    for (0..@min(buffer.content.items.len, dims.height)) |row| {
        const line: []u8 = buffer.content.items[row].items;
        const line_view = try std.unicode.Utf8View.init(line);
        var line_iter = line_view.iterator();
        try term.move_cursor(.{ .row = @intCast(row), .col = 0 });

        var col: usize = 0;
        while (line_iter.nextCodepoint()) |ch| {
            attrs_stream.reset();

            if (col < dims.width) {
                const ch_attrs: []co.Attr = b: for (buffer.spans.items) |span| {
                    if (span.span.start_byte <= byte and span.span.end_byte > byte) {
                        if (std.mem.eql(u8, span.node_type, "return") or
                            std.mem.eql(u8, span.node_type, "primitive_type") or
                            std.mem.eql(u8, span.node_type, "#include") or
                            std.mem.eql(u8, span.node_type, "export") or
                            std.mem.eql(u8, span.node_type, "function"))
                        {
                            break :b @constCast(co.attributes.keyword);
                        }
                        if (std.mem.eql(u8, span.node_type, "system_lib_string") or
                            std.mem.eql(u8, span.node_type, "string_literal") or
                            std.mem.eql(u8, span.node_type, "string"))
                        {
                            break :b @constCast(co.attributes.string);
                        }
                        if (std.mem.eql(u8, span.node_type, "number_literal")) {
                            break :b @constCast(co.attributes.number);
                        }
                        if (std.mem.eql(u8, span.node_type, "comment")) {
                            break :b @constCast(co.attributes.comment);
                        }
                    }
                } else {
                    break :b @constCast(co.attributes.text);
                };

                for (ch_attrs) |attr| {
                    try attr.write(attrs_stream.writer());
                }

                if (mode == .select) {
                    if (buffer.selection.?.in_range(.{ .line = row, .character = col })) {
                        for (co.attributes.selection) |attr| {
                            try attr.write(attrs_stream.writer());
                        }
                    }
                }

                if (buffer.diagnostics.items.len > 0) {
                    for (buffer.diagnostics.items) |diagnostic| {
                        const range = diagnostic.range;
                        // TODO: multiline diagnostics
                        if (row == range.start.line and col >= range.start.character and col <= range.end.character) {
                            for (co.attributes.diagnostic_error) |attr| {
                                try attr.write(attrs_stream.writer());
                            }
                            break;
                        }
                    }
                }

                attrs = attrs_stream.getWritten();
                if (last_attrs == null or !std.mem.eql(u8, attrs, last_attrs.?)) {
                    term.reset_attributes() catch {};
                    try term.write(attrs);
                }

                @memcpy(&last_attrs_buf, &attrs_buf);
                last_attrs = last_attrs_buf[0..try attrs_stream.getPos()];

                try term.format("{u}", .{ch});
            }
            byte += try std.unicode.utf8CodepointSequenceLength(ch);
            col += 1;
        }
        byte += 1;
    }
    try term.move_cursor(cursor);

    switch (mode) {
        .normal, .select => _ = try term.write(ter.cursor_type.steady_block),
        .insert => _ = try term.write(ter.cursor_type.steady_bar),
    }

    try term.flush();
}

pub fn main() !void {
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

    term = try ter.Term.init(std_out);
    defer term.deinit();

    try redraw();

    const lsp_conf = lsp.LspConfig{ .cmd = &[_][]const u8{ "typescript-language-server", "--stdio" } };
    var lsp_conn = try lsp.LspConnection.connect(allocator, &lsp_conf);
    defer lsp_conn.deinit();

    main_loop: while (true) {
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
                    buffer.move_cursor(.{ .row = cursor.row - 1, .col = cursor.col });
                } else if (code == .down) {
                    buffer.move_cursor(.{ .row = cursor.row + 1, .col = cursor.col });
                } else if (code == .left) {
                    buffer.move_cursor(.{ .row = cursor.row, .col = cursor.col - 1 });
                } else if (code == .right) {
                    buffer.move_cursor(.{ .row = cursor.row, .col = cursor.col + 1 });
                } else if (code == .escape) {
                    mode = .normal;
                    needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{mode});

                    // single-key normal or select mode
                } else if (normal_or_select and ch == 'q') {
                    break :main_loop;
                } else if (normal_or_select and ch == 'i') {
                    buffer.move_cursor(.{ .row = cursor.row - 1, .col = cursor.col });
                } else if (normal_or_select and ch == 'k') {
                    buffer.move_cursor(.{ .row = cursor.row + 1, .col = cursor.col });
                } else if (normal_or_select and ch == 'j') {
                    buffer.move_cursor(.{ .row = cursor.row, .col = cursor.col - 1 });
                } else if (normal_or_select and ch == 'l') {
                    buffer.move_cursor(.{ .row = cursor.row, .col = cursor.col + 1 });

                    // single-key normal mode
                } else if (mode == .normal and ch == 's') {
                    mode = .select;
                    try buffer.select_char();
                    needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{mode});
                } else if (mode == .normal and ch == 'h') {
                    mode = .insert;
                    needs_redraw = true;
                    log.log(@This(), "mode: {}\n", .{mode});

                    // single-key insert mode
                } else if (mode == .insert and code == .delete) {
                    try buffer.remove_char();
                } else if (mode == .insert and code == .backspace) {
                    try buffer.remove_prev_char();
                } else if (mode == .insert and code == .enter) {
                    try buffer.insert_newline();
                } else if (mode == .insert and key.printable != null) {
                    try buffer.insert_text(key.printable.?);
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
