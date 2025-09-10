# Hat

Hat is a **ha**ckable modal **t**ext editor for modern terminals.

| ![Screenshot select](./img/screenshot-select.png) | ![Screenshot select](./img/screenshot-find.png) |
|-----------------------------|-----------------------------|
| ![Screenshot completion](./img/screenshot-cmp.png) | ![Screenshot diagnostics](./img/screenshot-diagnostics.png) |

## Features

### Core functionality

- Modal text editing
    * Normal, select, select line, and insert modes
    * Basic motions (vim's `e` `y` `o` `p` `a` `d` `f` `c` `b` `^` `$` `0` `=` `J` `gJ` `*` `#` etc.)
    * Unlimited undo/redo
    * System clipboard copy & paste (using `xclip`)
    * Find in buffer
- Text automation
    * Run external command on selection
    * Dot repeat last change
    * Multi repeat
    * Macros
- [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) syntax awareness
    * Syntax highlighting (24 bit color)
    * Indent alignment
- [LSP](https://microsoft.github.io/language-server-protocol/) support
    * Go to definition
    * Find references
    * Diagnostics
    * Completions w/ documentation
    * Hover
    * Rename
- Multi buffer
    * Buffer management
    * Find file
    * Find in files
- Scratch buffers
- Unicode support
- `--printer` mode

### Functionality available in patches

| Done | Name                      | Link                                                  |
| ---- | ------------------------  | ----------------------------------------------------- |
| ✔️   | LSP highlight             | [patch/lsp-highlight](/patch/lsp-highlight)           |
| ✔️   | LSP code action           | [patch/lsp-code-action](/patch/lsp-code-action)       |
| ✔️   | LSP formatting            | [patch/lsp-formatting](/patch/lsp-formatting)         |
| ✔️   | Git hunk markers          | [patch/git-signs](/patch/git-signs)                   |
| ✔️   | Tree-sitter symbol picker | [patch/ts-symbol-picker](/patch/ts-symbol-picker)     |
| ✔️   | Buffer centering          | [patch/buffer-centering](/patch/buffer-centering)     |
| ✔️   | Autosave                  | [patch/autosave](/patch/autosave)                     |
| ✔️   | Relative line numbers     | [patch/relative-number](/patch/relative-number)       |
| ✔️   | Auto-indent               | [patch/auto-indent](/patch/auto-indent)               |
| 🚧   | Windows support           |                                                       |
| 🚧   | MacOS support             |                                                       |
| 🚧   | Wayland support           |                                                       |
| 🚧   | Persistent undo           |                                                       |
| 🚧   | Persistent macros         |                                                       |
| 🚧   | Tree-sitter tree actions  |                                                       |
| 🚧   | Surround actions          |                                                       |
| 🚧   | Case actions              |                                                       |
| 🚧   | Marks                     |                                                       |
| 🚧   | Comments                  |                                                       |
| 🚧   | List mode                 |                                                       |

## Philosophy

Based on [suckless](https://suckless.org/philosophy/) and
[unix](https://en.wikipedia.org/wiki/Unix_philosophy) philosophies.

Software is:
- doing not more and not less than what the user needs
    * Every feature is implemented in the most simple and straightforward form: keep it simple, fast, and clear
- made for users capable of reading and customizing its source code
    * Source code can be read by users in one evening
    * External configuration is not necessary and discouraged
    * User manual documentation is not necessary, _hacking_ documentation is encouraged (via [`HACKING.md`](HACKING.md))
- distributed as source code, compiled by the user
- not meant to be developed forever and its final state should be described by its feature set from
the beginning
- extended either by the user directly or by applying
[source code patches](https://en.wikipedia.org/wiki/Patch_(computing)#Source_code_patching), distributed as diff files
    * It is encouraged to share your extensions with others who can find it useful

## Build, install, usage, configuration

See [`HACKING.md`](HACKING.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md).
