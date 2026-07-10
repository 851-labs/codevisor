#!/usr/bin/env bash
# Tells agents in a fresh checkout how to initialize reference repositories.
# Reference submodules are deliberately left uninitialized so worktree creation
# stays fast and agents only fetch the repositories they actually need.
set -euo pipefail

prev_head="${1:-}"
flag="${3:-}"
null_sha="0000000000000000000000000000000000000000"

[ "$flag" = "1" ] || exit 0
[ "$prev_head" = "$null_sha" ] || exit 0

echo "Reference repositories are available as submodules in .repos/."
echo "Initialize one when needed: git submodule update --init .repos/<repository>"
