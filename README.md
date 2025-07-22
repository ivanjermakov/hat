# Hat

**Ha**ckable **t**ext editor

Hat is a [suckless](https://suckless.org/) modal text editor for modern terminals.

| ![Screenshot select](./img/screenshot-select.png) | ![Screenshot select](./img/screenshot-find.png) |
|-----------------------------|-----------------------------|
| ![Screenshot completion](./img/screenshot-cmp.png) | ![Screenshot diagnostics](./img/screenshot-diagnostics.png) |

## Philosophy

- Based on [suckless](https://suckless.org/philosophy/) and
[unix](https://en.wikipedia.org/wiki/Unix_philosophy) philosophies
- Software should do not more and not less than what users need
    * Every feature is implemented in the most simple and straightforward form: keep it simple, fast, and clear
- Software is made for users capable of reading and customizing its source code
    * Source code can be read by users in one evening
    * External configuration is not necessary and discouraged
    * User manual documentation is not necessary, _hacking_ documentation is encouraged (via [HACKING.md](HACKING.md))
- Software is meant to be distributed as source code, compiled by users
- Software is not meant to be developed forever and its final state should be described by its feature set from
the beginning
    * Once every feature is implemented, software can be considered complete
- Software is extended either by users directly or by applying
[source code patches](https://en.wikipedia.org/wiki/Patch_(computing)#Source_code_patching), distributed as diff files
    * It is encouraged to share your extensions with others who can find it useful

## Features

- [x] Modal text editing
    * [x] Unlimited undo/redo
    * [x] Select and select line modes
    * [ ] Select block mode
    * [x] System clipboard copy & paste (using `xclip`)
- [x] [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) syntax awareness
    * [x] Syntax highlighting (24 bit color)
    * [ ] Syntax tree actions
- [x] [LSP](https://microsoft.github.io/language-server-protocol/) support
    * [x] Diagnostics
    * [x] Completions w/ documentation
    * [x] Hover
    * [ ] Find symbol
- [x] Multi buffer
    * [x] Buffer management
    * [x] Find in files
- [x] Scratch buffers
- [x] Unicode support
- [x] `--printer` mode
