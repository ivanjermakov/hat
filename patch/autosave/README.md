# Autosave

Adds editor option `.autosave`.

When enabled, every `Buffer.commitChanges` will be followed by write to disk.

## Usage

Configure autosave fields in `config` in `editor.zig`:

```zig
.autosave = true,
```
