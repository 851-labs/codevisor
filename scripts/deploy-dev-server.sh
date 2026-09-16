#!/usr/bin/env bash
# Builds codevisor-server from this working tree on a Linux box that was set
# up with the public installer, and swaps it into /opt/codevisor there
# (docs/plans/screen-sharing-vps.md, stage 5). The box builds natively: the
# release runtime compiles Node addons, so it cannot be cross-built here.
#
#   scripts/deploy-dev-server.sh root@HOST
#
# Needs on the box: Node 24 at /opt/node24, bun in ~/.bun, build-essential.
# Data (~/.codevisor/data, cloud pairing included) is untouched; the previous
# runtime stays in /opt/codevisor.prev.
set -euo pipefail

target=${1:-}
[[ -n "$target" ]] || { echo "Usage: $0 user@host" >&2; exit 2; }
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="0.1.999-dev.$(git -C "$repo_root" rev-parse --short HEAD)"
source_dir=/root/codevisor-src

echo "Syncing the working tree to $target:$source_dir"
rsync -az --delete \
  --exclude .git --exclude node_modules --exclude tmp --exclude dist --exclude .build \
  --exclude '*.tsbuildinfo' --exclude coverage \
  --exclude .repos --exclude .codevisor --exclude DerivedData --exclude .turbo \
  --exclude apps/macos --exclude apps/ios --exclude apps/screen-sharing-rig \
  --exclude packages/swift --exclude '*.xcodeproj' \
  "$repo_root/" "$target:$source_dir/"

ssh "$target" "VERSION=$version SOURCE_DIR=$source_dir bash -s" <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.bun/bin:/opt/node24/bin:$PATH"
cd "$SOURCE_DIR"
echo "Installing dependencies"
bun install --frozen-lockfile >/tmp/codevisor-bun-install.log 2>&1 || { tail -20 /tmp/codevisor-bun-install.log; exit 1; }
echo "Building the server's workspace dependencies"
# Composite tsc trusts buildinfo over missing output; never carry any over.
find . -name "*.tsbuildinfo" -not -path "*/node_modules/*" -delete
rm -rf .turbo node_modules/.cache/turbo
# @codevisor/api first: not every package that imports it declares it.
bunx turbo run build --force --filter=@codevisor/api >/tmp/codevisor-deps-build.log 2>&1 &&
  bunx turbo run build --force --filter='@codevisor/server...' >>/tmp/codevisor-deps-build.log 2>&1 ||
  { tail -20 /tmp/codevisor-deps-build.log; exit 1; }
echo "Building the runtime $VERSION"
CODEVISOR_RELEASE_NODE=/opt/node24/bin/node scripts/release/build-server-runtime.sh "$VERSION" /root/codevisor-runtime linux-x64 \
  >/tmp/codevisor-runtime-build.log 2>&1 || { tail -30 /tmp/codevisor-runtime-build.log; exit 1; }
echo "Swapping /opt/codevisor"
systemctl stop codevisor-server
rm -rf /opt/codevisor.prev
mv /opt/codevisor /opt/codevisor.prev
cp -R /root/codevisor-runtime /opt/codevisor
systemctl start codevisor-server
for _ in $(seq 1 30); do
  if info=$(curl -fsS http://127.0.0.1:49361/v1/info 2>/dev/null); then
    echo "$info" | tr ',' '\n' | grep -E '"version"|screen-sharing-v1' || true
    exit 0
  fi
  sleep 1
done
echo "codevisor-server did not come up" >&2
journalctl -u codevisor-server --no-pager -n 20
exit 1
REMOTE
