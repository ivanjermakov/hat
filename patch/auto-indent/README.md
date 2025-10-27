# Auto-indent

Tree-sitter powered insert mode auto-indenting.

Adds editor options:

- `indent_newline`: auto-indent inserted newline
- `reindent_block_end_chars`: reindent current line upon insertion of one of these chars

## Usage

Configure auto-indent fields in `Config` in `editor.zig`:

```zig
pub const indent_newline: bool = true;
pub const reindent_block_end_chars: ?[]const u21 = &.{ '}', ']', ')' };
```
