# Autosave

Adds editor option `autosave`.

When enabled, every `Buffer.commitChanges` will be followed by write to disk.

## Usage

Configure autosave fields in `Config` in `editor.zig`:

```zig
pub const autosave: bool = true;
```
