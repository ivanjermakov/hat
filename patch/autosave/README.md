# Autosave

Adds editor option `.autosave`.

When enabled, every `Buffer.commitChanges` will be followed by write to disk.

## Usage

Initialize editor with `.autosave` field.

```zig
editor = try edi.Editor.init(allocator, .{ .autosave = true });
```

Autosaving everything might not be a good idea, I recommend only performing autosave if file is within git root.
Update autosave checks with git root (added by [patch/git-signs](/patch/git-signs)):

```zig
if (main.editor.config.autosave and self.git_root != null) {
```
