# Ghostty terminfo

Compiled `ghostty` / `xterm-ghostty` terminfo entries copied from
`apps/macos/Codevisor/Resources/ghostty-resources.tar.gz` and built from the
Ghostty revision pinned by `apps/macos/scripts/build-ghostty.sh`.

The Codevisor server points PTY children at this database with `TERMINFO`, so
remote machines do not need Ghostty or a system-wide terminfo installation.
`GHOSTTY-LICENSE` contains the upstream MIT license.
