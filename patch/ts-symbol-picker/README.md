# Tree-sitter symbol picker

Fzf picker listing document symbols based on tree-sitter query.

## Usage

Add `symbol_query` to your `file_type` config.
Query will only handle `@name` captures.

```zig
pub const file_type = std.StaticStringMap(FileTypeConfig).initComptime(.{
    .{ ".ts", FileTypeConfig{
        .name = "typescript",
        .ts = .{
            // ...
            .symbol_query = TsConfig.symbol_query_from_aerial("typescript"),
        },
    } },
});
```

Create a mapping:

```zig
} else if (editor.mode == .normal and eql(u8, multi_key, " f")) {
    try buffer.findSymbols();
```

## Screenshots

![Screenshot screen centering](/img/screenshot-ts-symbol-picker.png)

## Credit

- [aerial.nvim](https://github.com/stevearc/aerial.nvim)
