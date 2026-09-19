#!/bin/sh
# In-container bootstrap for the dev remote servers (Dev Direct / Dev Cloud).
#
# Runs inside a stock node image with bind mounts from the worktree's
# ignored tmp/:
#   /codevisor          — the Linux workspace copy (dists + manifests) that
#                         scripts/dev-containers.mjs assembles; this script
#                         installs Linux node_modules INTO it, so every byte
#                         stays under the worktree's tmp/ and dies with it.
#   /codevisor-state    — per-worktree state (the bun binary, the install
#                         signature) so second boots take seconds.
#   /codevisor-bun-cache — the machine-wide bun install cache shared by every
#                         worktree (content-addressed, so always safe).
#   /natives-check.mjs  — scripts/dev-container-natives.mjs, which proves the
#                         native addons load after an install.
#
# Everything after the first-boot install is just: node dist/main.js serve …
# — the identical command the same-host dev servers run on macOS.
set -eu

STATE=/codevisor-state
APP=/codevisor
BUN="$STATE/bun/bin/bun"

# Both dev containers share this state (and the workspace copy). Their
# first boots race the same bun download and the same node_modules
# install — serialize the whole provisioning phase; the loser wakes up,
# sees the completed signature, and skips.
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
  # The official installer is a bash script; slim's /bin/sh is dash.
  curl -fsSL https://bun.sh/install -o /tmp/bun-install.sh
  BUN_INSTALL="$STATE/bun" bash /tmp/bun-install.sh >/dev/null
fi

# node-pty's install script invokes node-gyp directly; provision it once
# into the tmp-mounted cache so installs never pay npm for it again.
export PATH="$STATE/npm-tools/bin:$PATH"
if ! command -v node-gyp >/dev/null 2>&1; then
  echo "[container] installing node-gyp into tmp-mounted cache"
  npm install -g --prefix "$STATE/npm-tools" node-gyp >/dev/null 2>&1
fi

# Harness installs belong to the machine, not the disposable container
# filesystem. `/root` is a per-remote bind mount, so keep global npm CLIs and
# the common user-local installer locations there and put them on PATH.
export NPM_CONFIG_PREFIX=/root/.npm-global
export PATH="/root/.npm-global/bin:/root/.local/bin:/root/bin:$PATH"

cd "$APP"
LOCK_SIGNATURE="$(cat bun.lock bun.lockb 2>/dev/null | cksum | cut -d' ' -f1)"
INSTALLED_SIGNATURE="$(cat "$STATE/installed.signature" 2>/dev/null || true)"
if [ ! -d node_modules ] || [ "$LOCK_SIGNATURE" != "$INSTALLED_SIGNATURE" ]; then
  echo "[container] bun install (linux node_modules under tmp/)"
  # A partial tree from an interrupted install makes bun skip package
  # install scripts on retry — natives then load nothing. Start clean;
  # the bun cache keeps this fast.
  rm -rf node_modules
  # The machine-wide Linux bun cache when the runner mounted it (see
  # linuxBunCacheRoot in dev-containers.mjs), else a per-worktree one.
  if [ -d /codevisor-bun-cache ]; then BUN_CACHE=/codevisor-bun-cache; else BUN_CACHE="$STATE/bun-cache"; fi
  BUN_INSTALL_CACHE_DIR="$BUN_CACHE" "$BUN" install --frozen-lockfile
  # The native addons must load — from the workspaces that declare them,
  # the only place bun's isolated linker links them — before this install
  # counts. There is deliberately no repair step: after a clean install a
  # failure here means an addon's Linux build broke, and the fix belongs in
  # the lockfile or the image, not in an ad-hoc rebuild by another package
  # manager that runs the package's own build scripts.
  echo "[container] verifying native addons"
  if ! node /natives-check.mjs "$APP"; then
    echo "[container] native addons failed to load after a clean install (see above)." >&2
    echo "[container] Delete the worktree's tmp/container to retry from scratch." >&2
    exit 1
  fi
  echo "$LOCK_SIGNATURE" > "$STATE/installed.signature"
fi

flock -u 9

# One-shot provisioning mode: the runner boots this once (and waits)
# before starting the two server containers, because they share this
# state and cross-VM file locks cannot serialize their first boots.
if [ "${1:-}" = "--provision-only" ]; then
  echo "[container] provisioning complete"
  exit 0
fi

echo "[container] starting server: $*"
exec node apps/server/dist/main.js "$@"
