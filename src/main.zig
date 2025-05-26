const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
    @cInclude("tree_sitter/tree-sitter-c.h");
});
const nc = @cImport({
    @cInclude("ncurses.h");
});

const Buffer = std.ArrayList(Line);

const Line = std.ArrayList(u8);

fn buffer_new(content: []u8, alloc: std.mem.Allocator) !Buffer {
    var lines_iter = std.mem.split(u8, content, "\n");
    var lines: Buffer = std.ArrayList(Line).init(alloc);
    while (true) {
        const next: []u8 = @constCast(lines_iter.next() orelse break);
        var line = std.ArrayList(u8).init(alloc);
        try line.appendSlice(next);
        try lines.append(line);
    }
    return lines;
}

// pub fn main() !void {
//     const parser = ts.ts_parser_new();
//     const language = ts.tree_sitter_c();
//     _ = ts.ts_parser_set_language(parser, language);
//
//     const source_code = "int main() { return 0; }";
//     const tree = ts.ts_parser_parse_string(parser, null, source_code, source_code.len);
//
//     const root_node = ts.ts_tree_root_node(tree);
//     std.debug.print("tree: {s}\n", .{@as([*:0]u8, ts.ts_node_string(root_node))});
//
//     ts.ts_tree_delete(tree);
//     ts.ts_parser_delete(parser);
// }

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse return error.NoPath;

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });

    var buf: []u8 = try allocator.alloc(u8, 2048);
    const file_len = try file.readAll(buf);
    const buffer = try buffer_new(buf[0..file_len], allocator);

    const win = nc.initscr();

    for (0..buffer.items.len) |line| {
        const str: [*]u8 = @ptrCast(buffer.items[line].items);
        // TODO: why this is necessary
        if (buffer.items[line].items.len == 0) continue;
        _ = nc.mvwaddstr(win, @intCast(line), 0, str);
    }

    _ = nc.wmove(win, 0, 0);
    _ = nc.refresh();

    while (true) {
        const key = nc.getch();
        if (key == 'q') {
            _ = nc.endwin();
            return;
        }
    }
}
