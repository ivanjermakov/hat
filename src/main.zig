const std = @import("std");
const ts = @cImport({
    @cInclude("tree_sitter/api.h");
    @cInclude("tree_sitter/tree-sitter-c.h");
});

pub fn main() !void {
    const parser = ts.ts_parser_new();
    const language = ts.tree_sitter_c();
    _ = ts.ts_parser_set_language(parser, language);

    const source_code = "int main() { return 0; }";
    const tree = ts.ts_parser_parse_string(parser, null, source_code, source_code.len);

    const root_node = ts.ts_tree_root_node(tree);
    std.debug.print("Root node type: {*}\n", .{ts.ts_node_type(root_node)});

    ts.ts_tree_delete(tree);
    ts.ts_parser_delete(parser);
}
