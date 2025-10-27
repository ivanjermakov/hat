# Autosave

Adds editor option `autosave`.

When enabled, every `Buffer.commitChanges` will be followed by write to disk.

## Usage

Configure autosave fields in `Config` in `editor.zig`:

```zig
pub const autosave: bool = true;
```

Autosaving everything might not be a good idea, I recommend only performing autosave if file is within git root.
Update autosave checks with git root (added by [patch/git-signs](/patch/git-signs)):

```zig
if (main.editor.config.autosave and self.git_root != null) {
```
