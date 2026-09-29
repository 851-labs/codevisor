# Ghostty terminfo

Compiled `ghostty` / `xterm-ghostty` terminfo entries copied from
`apps/macos/Codevisor/Resources/ghostty-resources.tar.gz` and built from the
Ghostty revision pinned by `apps/macos/scripts/build-ghostty.sh`.

Both ncurses directory conventions are included: macOS looks in hexadecimal
`67/` and `78/` buckets, while Linux looks in first-character `g/` and `x/`
buckets. The compiled entries are identical; only their lookup paths differ.

The Codevisor server points macOS PTY children at this database with `TERMINFO`
and advertises `xterm-ghostty`. Linux PTYs use the host's standard
`xterm-256color` database and retain `COLORTERM=truecolor`; they deliberately
omit `TERMINFO` so the Ghostty-only bundle cannot mask system entries in Zsh.
`GHOSTTY-LICENSE` contains the upstream MIT license.

# libghostty-vt (WebAssembly)

`ghostty-vt.wasm` is libghostty-vt built for `wasm32-freestanding`
(`ReleaseSmall`) from the Ghostty revision in `GHOSTTY-VT-REF`, by
`scripts/build-ghostty-vt-wasm.sh`. The build is reproducible: rerunning the
script at the same revision with Zig 0.16.0 yields identical bytes. The server
keeps an authoritative copy of each terminal's screen in it, so reattaching
clients receive a reconstruction of the current screen instead of the
terminal's whole output history (`src/vt/ghostty-vt.ts`).

# Ghostty shell integration

`shell-integration/` is Ghostty's `src/shell-integration` tree, copied unmodified from the Ghostty
revision in `GHOSTTY-VT-REF`. Shells the server starts load it the way Ghostty's
`src/termio/shell_integration.zig` injects it (`src/shell-integration.ts`), so they report the
running command as the title and emit OSC 133 prompt marks. The fish, elvish, and nushell scripts
are Ghostty's MIT (`GHOSTTY-LICENSE`), and `bash-preexec.sh` is rcaloras/bash-preexec (MIT). The
zsh and `ghostty.bash` scripts derive from Kitty's and are GPLv3, as their headers state; they are
standalone scripts the shell sources, not linked into Codevisor.
