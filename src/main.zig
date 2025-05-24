const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
    @cInclude("tree_sitter/tree-sitter-c.h");
});
const nc = @cImport({
    @cInclude("ncurses.h");
});

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
    var args = std.process.args();
    _ = args.skip();
    const path = args.next() orelse return error.NoPath;

    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });

    var buffer: []u8 = try std.heap.page_allocator.alloc(u8, 2048);
    const file_len = try file.readAll(buffer);
    const content: []u8 = buffer[0..file_len];

    const win = nc.initscr();
    _ = nc.printw(@ptrCast(content));
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
