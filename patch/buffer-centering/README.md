# Buffer centering

Adds editor option `centering_width`

* `centering_width = N` means that the buffer will be left padded, so that line with N width is horizontally
centered within the terminal
* `centering_width = null` means do not pad, default behavior

## Usage

Configure fields in `Config` in `editor.zig`:

```zig
pub const centering_width: ?usize = 140;
```

## Screenshots

![Screenshot screen centering](/img/screenshot-screen-centering.png)
