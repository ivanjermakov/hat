### Dependencies

- [Zig](https://ziglang.org) (version >= `minimum_zig_version` in [build.zig.zon](build.zig.zon))
- [tree-sitter](https://tree-sitter.github.io/tree-sitter/)
- [pcre2](https://github.com/PCRE2Project/pcre2)

## Install

Hat should work out of the box on any
[`std.posix`-compliant](https://github.com/ziglang/zig/blob/master/lib/std/posix.zig) operating system with satisfied
dependencies and correct tree-sitter configuration (see `file_type` in [file_type.zig](src/file_type.zig)).

### Build

For development build:

```bash
zig build
```

For release build:

```bash
zig build --release=fast
```

Once built, executable can be found at `zig-out/bin`. For more info, see `zig build --help`.

