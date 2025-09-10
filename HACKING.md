## Files

- `src/main.zig`: entrypoint, update loop, key mappings
- `src/file_type.zig`: per-filetype configuration of LSP clients, Tree-sitter parser, other user preferences
- `src/lsp.zig`: LSP clients configuration & interface
- `src/editor.zig`: editor lifecycle, cross-buffer actions
- `src/buffer.zig`: buffer manipulation, edit engine, change history
- `src/core.zig`: common structs
- `src/terminal.zig`: tty input read & parse, tty output (draw to terminal)
- `src/ts.zig`: Tree-sitter C library wrapper
- `src/ui/*`: dir with UI components used in `Terminal.draw`
- `src/printer.zig`: one-shot buffer printer, similar to `cat`/`bat`
- `src/color.zig`: helper in theming with ANSI codes
- `src/input.zig`: key abstraction
- `src/external.zig`: helper in running external programs
- `src/cli.zig`: CLI arg parse
- `src/test_runner.zig`: custom test runner

## Design

Editor is running in fixed-time update loop:
- poll user input (/dev/tty) codes
- convert ANSI codes into `Key`s and write into `key_queue`
- consume keys from queue and match user defined mappings
- apply dirty actions:
    * buffer changes
    * terminal update
    * LSP servers
    * Tree-sitter state
- sleep until next loop iteration

Editor is multi-threaded: main thread and one thread for each LSP client, running `LspConnection.lspLoop`.

Buffer content is stored in two flat array lists:
- .content `[]u21` with Unicode codepoints
- .content_raw `[]u8` with raw bytes

Buffer content is updated using `Change`s allowing incremental update and history:
- `Change` is a struct describing the reversible content change (old_text -> new_text, old_span -> new_span)
- .history `[][]Change` is list of changelists
- .uncommitted_changes `std.array_list.Aligned(cha.Change, null)` is a changelist that is not yet committed to history

`Editor` keeps track of all open buffers (`.buffers`) and LSP connections (`lsp_connections`).

`Terminal` takes editor state and draws it into stdout.

## Build

Hat should work out of the box on any
[`std.posix`-compliant](https://github.com/ziglang/zig/blob/master/lib/std/posix.zig) operating system with satisfied
dependencies and correct tree-sitter configuration (see `file_type` in [file_type.zig](src/file_type.zig)).

### Dependencies

- [Zig](https://ziglang.org) (version >= `minimum_zig_version` in [build.zig.zon](build.zig.zon))
- [tree-sitter](https://tree-sitter.github.io/tree-sitter/)
- [pcre2](https://github.com/PCRE2Project/pcre2)

Development build:

```bash
zig build
```

Release build:

```bash
zig build --release=fast
```

Once built, executable can be found at `zig-out/bin`. For more info, see `zig build --help`.

Run tests:

```bash
zig build test
```

## FAQ

### How to apply patches?

Using `patch(1)` or `git apply`:

```bash
git apply patch/mypatch/mypatch.diff
```

Additional flags might help with conflict resolution:

```bash
git apply --3way patch/mypatch/mypatch.diff
```

### How to customize key mappings?

See `src/main.zig`, change or add a new clause with your key mapping:

```zig
} else if (editor.mode == .normal and eql(u8, key, "G")) {
    try editor.sendMessage("G pressed!");
```

Note that ordering is important, first matching condition consumes the key(s).

### How to customize color theme?

See `attributes` and `color` in `src/color.zig`.

### How to set up a custom file type?

Add a new entry in `file_type` in `file_type.zig`.
For Tree-sitter features, initialize `ts: TsConfig`.

Example configuration for Rust using `nvim-treesitter` queries:

```zig
.{ ".rs", FileTypeConfig{
    .name = "rust",
    .ts = TsConfig.from_nvim("rust"),
} },
```

### How to set up a custom LSP client?

- Add a new entry in `file_type` in `file_type.zig` for your filetype if missing.
- Add a new entry in `lsp_config` in `lsp.zig` with your filetype.

Example configuration for Rust and `rust-analyzer`:

```zig
.{ ".rs", FileTypeConfig{
    .name = "rust",
    .ts = TsConfig.from_nvim("rust"),
} },
```

```zig
LspConfig{
    .name = "rust-analyzer",
    .cmd = &.{ "rust-analyzer" },
    .file_types = &.{"rust"},
},
```

### How to add a new picker, similar to "find in files"?

See implementation of `Editor.findInFiles`.
Hat spawns `fzf` with piped input and handles output as selected item.

### How to add a new UI element, for example status line?

- See `Terminal.draw` and `Terminal.drawOverlay`
- If some custom data is needed, expand the `Editor` struct, similar to `Editor.completion_menu`
- To make it performant, make sure to update it only when necessary, using `Editor.dirty` flags
- When layout changes are needed, update `Terminal.computeLayout` accordingly

### How to add a new command?

See `Command` in `command_line.zig` and `Editor.handleCmd`. Add a new value and implement the handler.
