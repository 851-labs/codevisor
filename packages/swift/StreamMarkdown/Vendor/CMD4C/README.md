# MD4C

This directory vendors the UTF-8 MD4C parser used by `StreamMarkdown`.

- Upstream: https://github.com/mity/md4c
- Version: 0.5.3
- Commit: `472c417005c2c71b8617de4f7b8d6b30411d78f4`
- License: MIT; see `LICENSE.md`

The parser uses `src/md4c.c`/`src/md4c.h`. `src/entity.c`/`src/entity.h` are
also vendored from the same commit because MD4C deliberately delegates HTML5
named-entity decoding to its host. To upgrade, replace all four files from the
same upstream commit, update this record, and run the parser, streaming,
rendering tests and release-mode parser benchmark before landing the change.
