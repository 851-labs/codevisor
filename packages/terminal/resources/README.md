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
