# Relative line numbers

Adds editor option `.number_line_mode` with values `.absolute` (default) and `.relative`.

Changes number line to show line numbers relative to cursor.
Similar to Vim's [`relativenumber`](https://vimhelp.org/options.txt.html#%27relativenumber%27).

# Usage

Initialize editor with `.number_line_mode = .relative`.

```zig
editor = try edi.Editor.init(allocator, .{ .number_line_moe = .relative });
```
