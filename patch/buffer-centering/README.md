# Buffer centering

Adds editor option `.centering_width`

* `.centering_width = N` means that the buffer will be left padded, so that line with N width is horizontally
centered within the terminal
* `.centering_width = null` means do not pad, default behavior

## Usage

Configure fields in `config` in `editor.zig`:

```zig
.centering_width = 140,
```

## Screenshots

![Screenshot screen centering](/img/screenshot-screen-centering.png)
