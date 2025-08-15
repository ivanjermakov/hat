# LSP code action

LSP `textDocument/codeAction` support.

# Usage

Define a keymap to invoke `Buffer.codeAction()`:

```zig
} else if (editor.mode == .normal and eql(u8, multi_key, " c")) {
    try buffer.codeAction();
```

Optionally configure `hint_bag` with a desired keys to apply code action:

```zig
pub const hint_bag: []const u8 = &.{ 'f', 'j', 'd', 'k', 's', 'l', 'a', 'b', 'c', 'e', 'g', 'h', 'i', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z' };
```
