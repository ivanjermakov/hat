const ts_c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Span = struct {
    start_byte: usize,
    end_byte: usize,
};

pub const NodeType = []u8;

pub const SpanNodeTypeTuple = struct {
    span: Span,
    node_type: NodeType,
};

pub const ts = ts_c;
