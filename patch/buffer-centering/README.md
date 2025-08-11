# Buffer centering

Adds editor option `.centering_width`

* `.centering_width = N` means that the buffer will be left padded, so that line with N width is horizontally
centered within the terminal
* `.centering_width = null` means do not pad, default behavior

## Usage

Initialize editor with `.centering_width` field.

```zig
editor = try edi.Editor.init(allocator, .{ .centering_width = 140 });
```

## Screenshots

![Screenshot screen centering](/img/screenshot-screen-centering.png)
