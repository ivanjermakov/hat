# Autosave

Adds editor option `.autosave`.

When enabled, every `Buffer.commitChanges` will be followed by write to disk.

## Usage

Initialize editor with `.autosave` field.

```zig
editor = try edi.Editor.init(allocator, .{ .autosave = true });
```
