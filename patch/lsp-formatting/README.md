# LSP formatting

LSP `textDocument/formatting` support.

# Usage

Define a keymap to invoke `Buffer.format()`:

```zig
} else if (editor.mode == .normal and eql(u8, multi_key, " l")) {
    buffer.format() catch |e| log.err(@This(), "format LSP error: {}", .{e}, @errorReturnTrace());
```
