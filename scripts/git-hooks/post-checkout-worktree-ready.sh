#!/usr/bin/env bash
# Prepares a checkout: keeps Xcode's DerivedData inside the worktree, installs
# dependencies when they are missing or the lockfile changed, and tells agents
# in a fresh checkout how to initialize reference repositories.
# Reference submodules are deliberately left uninitialized so worktree creation
# stays fast and agents only fetch the repositories they actually need.
set -euo pipefail

prev_head="${1:-}"
new_head="${2:-}"
flag="${3:-}"
null_sha="0000000000000000000000000000000000000000"

[ "$flag" = "1" ] || exit 0

root="$(git rev-parse --show-toplevel)"

# Best effort: a missing node must never fail a checkout.
if command -v node >/dev/null 2>&1; then
  node "$root/scripts/xcode-derived-data.mjs" ||
    echo "warning: could not configure Xcode DerivedData for this worktree" >&2
fi

lockfile_changed() {
  [ "$prev_head" != "$null_sha" ] && ! git diff --quiet "$prev_head" "$new_head" -- bun.lock
}

# Installs on .node-version's Node when fnm is available, so native addons
# download their prebuilt binaries instead of compiling for another Node.
install_dependencies() {
  if command -v fnm >/dev/null 2>&1; then
    fnm exec --using="$root/.node-version" -- bun install --frozen-lockfile
  else
    bun install --frozen-lockfile
  fi
}

# Best effort, like DerivedData: a failed install must never fail a checkout.
if command -v bun >/dev/null 2>&1 && { [ ! -d "$root/node_modules" ] || lockfile_changed; }; then
  (cd "$root" && install_dependencies) ||
    echo "warning: could not install dependencies; run bun install --frozen-lockfile" >&2
fi

[ "$prev_head" = "$null_sha" ] || exit 0

echo "Reference repositories are available as submodules in .repos/."
echo "Initialize one when needed: git submodule update --init .repos/<repository>"
