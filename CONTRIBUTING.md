> [!WARNING]
> Read through the [`README.md`](README.md) and [`HACKING.md`](HACKING.md) first.

## Principles

Users can do with this source code what they want, but contributions meant for everybody have to meet the following
principles:

- Resiliency
    * Hat is able to open and properly display any file, including Unicode and binary
    * LSP/file system/etc. errors are gracefully handled without crashing
- Consistency
    * Writing unedited buffer to file should produce empty diff
- Security
    * Hat won't read/write user files or do network request without explicit user action
    * Security cannot be guaranteed when working with malicious LSP clients or other external programs outside of Hat's
control

## Assumptions

Some assumptions were made to keep Hat simple:

- Unicode support is limited to what common modern terminal emulators support. In Hat, "character" is a Unicode
codepoint with non-zero width. So no grapheme clustering, no variation selection, no terminal emulator-specific logic.
As long as non-ascii characters are displayed and editable, we're ok.
- Hosting terminal emulator is capable of:
    * [Alternate buffer](https://unix.stackexchange.com/questions/288962/what-does-1049h-and-1h-ansi-escape-sequences-do)
    * [Wrap around](https://superuser.com/a/600694/1109910)
    * [24bit color](https://en.wikipedia.org/wiki/ANSI_escape_code#24-bit)
    * [Underline decorations](https://sw.kovidgoyal.net/kitty/underlines/)
    * Unicode rendering

## Contributing

### Improving core functionality

Open a PR into main with your changes. Unit tests for use cases solved with your changes are welcome.

### Extending functionality

Hat is extended by applying patches, see [`patch`](/patch) directory for example patches.

- Open a PR with a new patch. Each patch has it's own directory `patch/mypatch` with two mandatory files:
    * `README.md` with a brief description of functionality provided
    * `mypatch.diff` with a name matching the patch directory name
- If patch includes visual changes, add a screenshot to [`img`](/img) directory and link it in patch' `README.md`.
- Update repo's `README.md` patches table with `mypatch`

Patch file can be created using the following command:

```sh
git diff upstream/master mypatch
```

### Improving patches

Open a PR with changes in the [`patch`](/patch) directory.
