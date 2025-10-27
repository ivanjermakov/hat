# LSP code action

LSP `textDocument/codeAction` support.

# Usage

Define a keymap to invoke `Buffer.codeAction()`:

```zig
} else if (editor.mode == .normal and eql(u8, multi_key, " c")) {
    buffer.codeAction(action) catch |e| log.err(@This(), "code action LSP error: {}\n", .{e}, @errorReturnTrace());
```

Optionally configure `hint_bag` in `code_action.zig` with a desired hint keys to apply code action:

```zig
pub const hint_bag: []const u8 = &.{ 'f', 'j', 'd', 'k', 's', 'l', 'a', 'b', 'c', 'e', 'g', 'h', 'i', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z' };
```
