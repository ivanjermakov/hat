# Auto-indent

Tree-sitter powered insert mode auto-indenting.

Adds editor options:

- `.indent_newline`: auto-indent inserted newline
- `.reindent_block_end`: reindent current line upon insertion of one of `reindent_block_end_chars`

## Usage

Initialize editor with auto-indent fields:

```zig
editor = try edi.Editor.init(allocator, .{
    .indent_newline = true,
    .reindent_block_end = true,
});
```
