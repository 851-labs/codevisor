#!/usr/bin/env bash
# Restarts the Codevisor dev instance when app source has changed.
#
# Intended for a Stop hook, so it runs after each agent turn. Turns that only
# read code leave the running app alone — the rebuild is gated on a fingerprint
# of the Swift/TS sources the dev build actually compiles.
#
# Only ever signals the instance recorded in tmp/claude-dev-hook/dev.pid, so
# other worktrees' dev servers are never touched. That matches the one
# instance-per-worktree ownership rule in .claude/skills/run-dev.
#
# To enable, add to .claude/settings.local.json (paths resolve from the script
# itself, so the relative form works as long as hooks run at the repo root):
#
#   {
#     "hooks": {
#       "Stop": [
#         {
#           "hooks": [
#             {
#               "type": "command",
#               "command": "bash .claude/hooks/restart-dev.sh",
#               "async": true,
#               "statusMessage": "Restarting dev…"
#             }
#           ]
#         }
#       ]
#     }
#   }
#
# macOS only: it drives the Xcode build behind `bun run dev`.

set -uo pipefail

# Resolve the repo from the script's own location, so the hook works no matter
# what directory it is invoked from, and in any clone or worktree.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(git -C "$script_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$REPO" ] || exit 0
cd "$REPO" || exit 0

STATE_DIR="$REPO/tmp/claude-dev-hook"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/dev.pid"
HASH_FILE="$STATE_DIR/source.hash"
LOG_FILE="$STATE_DIR/dev.log"

# mtime+size of every source file the dev build compiles. Cheap enough to run
# every turn, and insensitive to reads/greps.
fingerprint() {
  find apps/macos/Codevisor apps/macos/Packages apps/server/src packages \
    -type f \( -name '*.swift' -o -name '*.ts' -o -name '*.tsx' \) \
    -not -path '*/node_modules/*' \
    -not -path '*/.build/*' \
    -not -path '*/dist/*' \
    -exec stat -f '%N %m %z' {} + 2>/dev/null | sort | md5
}

new_hash="$(fingerprint)"
old_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"

running=0
pid="$(cat "$PID_FILE" 2>/dev/null || true)"
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  running=1
fi

# Up to date and still alive: nothing to do.
if [ "$new_hash" = "$old_hash" ] && [ "$running" = "1" ]; then
  exit 0
fi

# Stop the instance we own and wait for it to release its port and app. dev.mjs
# tears down the server and the app on SIGTERM, so signal it rather than the
# children.
if [ "$running" = "1" ]; then
  kill -TERM "$pid" 2>/dev/null
  for _ in $(seq 1 60); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    sleep 1
  fi
fi
rm -f "$PID_FILE"

# Only override the toolchain when the active one cannot build — an
# xcode-select pointed at CommandLineTools makes xcodebuild fail. A machine
# already pointed at a real Xcode is left alone. Stable is preferred to beta.
if ! xcodebuild -version >/dev/null 2>&1; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      break
    fi
  done
fi

# Detached: the build takes minutes and must not hold the hook open.
nohup bun run dev >"$LOG_FILE" 2>&1 &
echo $! >"$PID_FILE"
echo "$new_hash" >"$HASH_FILE"
