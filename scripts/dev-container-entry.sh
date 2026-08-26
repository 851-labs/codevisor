#!/bin/sh
# In-container bootstrap for the dev remote servers (Dev Direct / Dev Cloud).
#
# Runs inside a stock node image with two bind mounts from the worktree's
# ignored tmp/:
#   /codevisor        — the Linux workspace copy (dists + manifests) that
#                       scripts/dev-containers.mjs assembles; this script
#                       installs Linux node_modules INTO it, so every byte
#                       stays under the worktree's tmp/ and dies with it.
#   /codevisor-state  — shared per-worktree cache (the bun binary, the bun
#                       install cache) so second boots take seconds.
#
# Everything after the first-boot install is just: node dist/main.js serve …
# — the identical command the same-host dev servers run on macOS.
set -eu

STATE=/codevisor-state
APP=/codevisor
BUN="$STATE/bun/bin/bun"

if [ ! -x "$BUN" ]; then
  echo "[container] installing bun (linux) into tmp-mounted cache"
  apt_missing=""
  command -v curl >/dev/null 2>&1 || apt_missing="curl"
  command -v unzip >/dev/null 2>&1 || apt_missing="$apt_missing unzip"
  if [ -n "$apt_missing" ]; then
    apt-get update -qq && apt-get install -y -qq $apt_missing >/dev/null
  fi
  # The official installer is a bash script; slim's /bin/sh is dash.
  curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh
  BUN_INSTALL="$STATE/bun" bash /tmp/bun-install.sh >/dev/null
fi

# node-pty's install script invokes node-gyp directly; provision it once
# into the tmp-mounted cache so rebuilds never pay npm again.
export PATH="$STATE/npm-tools/bin:$PATH"
if ! command -v node-gyp >/dev/null 2>&1; then
  echo "[container] installing node-gyp into tmp-mounted cache"
  npm install -g --prefix "$STATE/npm-tools" node-gyp >/dev/null 2>&1
fi

cd "$APP"
LOCK_SIGNATURE="$(cat bun.lock bun.lockb 2>/dev/null | cksum | cut -d' ' -f1)"
INSTALLED_SIGNATURE="$(cat "$STATE/installed.signature" 2>/dev/null || true)"
if [ ! -d node_modules ] || [ "$LOCK_SIGNATURE" != "$INSTALLED_SIGNATURE" ]; then
  echo "[container] bun install (linux node_modules under tmp/)"
  # A partial tree from an interrupted install makes bun skip package
  # install scripts on retry — natives then load nothing. Start clean;
  # the bun cache keeps this fast.
  rm -rf node_modules
  BUN_INSTALL_CACHE_DIR="$STATE/bun-cache" "$BUN" install --frozen-lockfile
  # Trusted natives must actually load before this install counts.
  if ! node -e "require('better-sqlite3'); require('node-pty')" 2>/dev/null; then
    echo "[container] native addons missing after install; rebuilding"
    npm rebuild better-sqlite3 node-pty
    node -e "require('better-sqlite3'); require('node-pty')"
  fi
  echo "$LOCK_SIGNATURE" > "$STATE/installed.signature"
fi

echo "[container] starting server: $*"
exec node apps/server/dist/main.js "$@"
