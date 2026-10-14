#!/bin/sh
set -eu

STATE=/codevisor-state
APP=/codevisor
BUN="$STATE/bun/bin/bun"

exec 9>"$STATE/.bootstrap.lock"
flock 9

if [ ! -x "$BUN" ]; then
  echo "[container] installing bun (linux) into tmp-mounted cache"
  apt_missing=""
  command -v curl >/dev/null 2>&1 || apt_missing="curl"
  command -v unzip >/dev/null 2>&1 || apt_missing="$apt_missing unzip"
  if [ -n "$apt_missing" ]; then
    apt-get update -qq && apt-get install -y -qq $apt_missing >/dev/null
  fi
  curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh
  BUN_INSTALL="$STATE/bun" bash /tmp/bun-install.sh >/dev/null
fi

export PATH="$STATE/npm-tools/bin:$PATH"
if ! command -v node-gyp >/dev/null 2>&1; then
  echo "[container] installing node-gyp into tmp-mounted cache"
  npm install -g --prefix "$STATE/npm-tools" node-gyp >/dev/null 2>&1
fi

export NPM_CONFIG_PREFIX=/root/.npm-global
export PATH="/root/.npm-global/bin:/root/.local/bin:/root/bin:$PATH"

cd "$APP"
LOCK_SIGNATURE="$(cat bun.lock bun.lockb 2>/dev/null | cksum | cut -d' ' -f1)"
INSTALLED_SIGNATURE="$(cat "$STATE/installed.signature" 2>/dev/null || true)"
if [ ! -d node_modules ] || [ "$LOCK_SIGNATURE" != "$INSTALLED_SIGNATURE" ]; then
  echo "[container] bun install (linux node_modules under tmp/)"
  rm -rf node_modules
  if [ -d /codevisor-bun-cache ]; then BUN_CACHE=/codevisor-bun-cache; else BUN_CACHE="$STATE/bun-cache"; fi
  BUN_INSTALL_CACHE_DIR="$BUN_CACHE" "$BUN" install --frozen-lockfile
  echo "[container] verifying native addons"
  if ! node /natives-check.mjs "$APP"; then
    echo "[container] native addons failed to load after a clean install (see above)." >&2
    echo "[container] Delete the worktree's tmp/container to retry from scratch." >&2
    exit 1
  fi
  echo "$LOCK_SIGNATURE" > "$STATE/installed.signature"
fi

flock -u 9

if [ "${1:-}" = "--provision-only" ]; then
  echo "[container] provisioning complete"
  exit 0
fi

if [ "${CODEVISOR_DEV_DESKTOP:-}" = "1" ]; then
  if sh /desktop.sh; then
    # shellcheck disable=SC1091
    . /tmp/desktop.env
  else
    echo "[container] the desktop didn't start; serving without it" >&2
    CODEVISOR_DEV_DESKTOP=0
  fi
fi
if [ "${CODEVISOR_DEV_DESKTOP:-}" != "1" ] && [ -n "${CODEVISOR_DATA_DIR:-}" ] &&
  grep -qs '"devContainerDesktop"' "$CODEVISOR_DATA_DIR/screen-sharing.json"; then
  rm -f "$CODEVISOR_DATA_DIR/screen-sharing.json"
fi

echo "[container] starting server: $*"
exec node apps/server/dist/main.js "$@"
