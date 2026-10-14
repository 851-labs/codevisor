#!/usr/bin/env bash
set -euo pipefail

prev_head="${1:-}"
new_head="${2:-}"
flag="${3:-}"
null_sha="0000000000000000000000000000000000000000"

[ "$flag" = "1" ] || exit 0

root="$(git rev-parse --show-toplevel)"

if command -v node >/dev/null 2>&1; then
  node "$root/scripts/xcode-derived-data.mjs" ||
    echo "warning: could not configure Xcode DerivedData for this worktree" >&2
fi

lockfile_changed() {
  [ "$prev_head" != "$null_sha" ] && ! git diff --quiet "$prev_head" "$new_head" -- bun.lock
}

install_dependencies() {
  if command -v fnm >/dev/null 2>&1; then
    fnm exec --using="$root/.node-version" -- bun install --frozen-lockfile
  else
    bun install --frozen-lockfile
  fi
}

if command -v bun >/dev/null 2>&1 && { [ ! -d "$root/node_modules" ] || lockfile_changed; }; then
  (cd "$root" && install_dependencies) ||
    echo "warning: could not install dependencies; run bun install --frozen-lockfile" >&2
fi

[ "$prev_head" = "$null_sha" ] || exit 0

echo "Reference repositories are available as submodules in .repos/."
echo "Initialize one when needed: git submodule update --init .repos/<repository>"
