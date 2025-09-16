# Auto-indent

Tree-sitter powered insert mode auto-indenting.

Adds editor options:

- `.indent_newline`: auto-indent inserted newline
- `.reindent_block_end`: reindent current line upon insertion of one of `reindent_block_end_chars`

## Usage

Configure auto-indent fields in `config` in `editor.zig`:

```zig
.indent_newline = true,
.reindent_block_end = true,
```
