#!/usr/bin/env bash
# Runs `refs pull` to sync ./references when a fresh worktree is created.
#
# Invoked by lefthook's post-checkout hook with the standard git args:
#   $1 = previous HEAD ref, $2 = new HEAD ref, $3 = flag (1 = branch checkout)
#
# On `git worktree add` (and fresh clones), git runs post-checkout with the
# previous HEAD set to the null SHA — that's how we detect "fresh" and skip
# ordinary branch switches.
set -euo pipefail

prev_head="${1:-}"
flag="${3:-}"

null_sha="0000000000000000000000000000000000000000"

# Only fire on a branch checkout (not a file checkout).
[ "$flag" = "1" ] || exit 0

# Only fire when this is a brand-new checkout (fresh worktree / clone).
[ "$prev_head" = "$null_sha" ] || exit 0

# Only fire if the refs CLI is installed.
if ! command -v refs >/dev/null 2>&1; then
  exit 0
fi

echo "Fresh worktree detected — syncing ./references via refs pull..."
refs pull
