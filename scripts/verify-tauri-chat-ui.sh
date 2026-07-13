#!/usr/bin/env bash
set -euo pipefail

# Captures the running Tauri dev app for chat UI visual QA.
#
# Preconditions:
# - `bun run dev:desktop` is running.
# - The dev server is reachable on CODEVISOR_DEV_SERVER_URL, default 49362.
# - macOS has granted screen-recording permission to the calling terminal/app.
#
# Tip: set CODEVISOR_VERIFY_ROUTE to a session route with `?verify=expanded`
# to force worked sections, tool groups, tool rows, and subagents open for
# deterministic transcript/tool-call screenshots, for example:
# CODEVISOR_VERIFY_ROUTE='/session/<id>?verify=expanded' bun run verify:tauri-chat
#
# Stable fixture routes for surfaces that may not exist in the shared dev DB:
# CODEVISOR_VERIFY_ROUTE='/verify/chat-parity' bun run verify:tauri-chat
# CODEVISOR_VERIFY_ROUTE='/verify/chat-composer' bun run verify:tauri-chat

SERVER_URL="${CODEVISOR_DEV_SERVER_URL:-http://127.0.0.1:49362}"
PROCESS_NAME="${CODEVISOR_TAURI_PROCESS:-codevisor-desktop}"
WINDOW_NAME="${CODEVISOR_TAURI_WINDOW-Codevisor}"
TAURI_BINARY="${CODEVISOR_TAURI_BINARY:-apps/desktop/src-tauri/target/debug/codevisor-desktop}"
VERIFY_ROUTE="${CODEVISOR_VERIFY_ROUTE:-}"
OUT_DIR="${1:-.tmp/chat-parity}"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$OUT_DIR"

HEALTH_PATH="$OUT_DIR/health-$STAMP.json"
SCREENSHOT_PATH="$OUT_DIR/tauri-chat-$STAMP.png"

curl -fsS "$SERVER_URL/v1/health" >"$HEALTH_PATH"

WINDOW_ID="$(
  CODEVISOR_TAURI_PROCESS="$PROCESS_NAME" CODEVISOR_TAURI_WINDOW="$WINDOW_NAME" swift -e '
import CoreGraphics
import Foundation

let targetOwner = ProcessInfo.processInfo.environment["CODEVISOR_TAURI_PROCESS"] ?? "codevisor-desktop"
let targetName = ProcessInfo.processInfo.environment["CODEVISOR_TAURI_WINDOW"] ?? "Codevisor"
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []

let candidates: [(id: Int, area: Int)] = windows.compactMap { window in
  let owner = window[kCGWindowOwnerName as String] as? String ?? ""
  let name = window[kCGWindowName as String] as? String ?? ""
  let layer = window[kCGWindowLayer as String] as? Int ?? -1
  let id = window[kCGWindowNumber as String] as? Int ?? 0
  guard owner == targetOwner, layer == 0, targetName.isEmpty || name == targetName else {
    return nil
  }
  guard let bounds = window[kCGWindowBounds as String] as? [String: Any] else { return nil }
  let width = bounds["Width"] as? Int ?? 0
  let height = bounds["Height"] as? Int ?? 0
  guard width > 200, height > 200 else { return nil }
  return (id, width * height)
}

if let best = candidates.sorted(by: { $0.area > $1.area }).first {
  print(best.id)
}
'
)"

if [[ -z "$WINDOW_ID" ]]; then
  echo "Could not find Tauri window owner='$PROCESS_NAME' name='$WINDOW_NAME'." >&2
  echo "Start the app with: bun run dev:desktop" >&2
  exit 1
fi

if [[ -n "$VERIFY_ROUTE" ]]; then
  if [[ ! -x "$TAURI_BINARY" ]]; then
    echo "Cannot route Tauri window: binary is not executable at '$TAURI_BINARY'." >&2
    echo "Set CODEVISOR_TAURI_BINARY or run bun run dev:desktop once." >&2
    exit 1
  fi
  "$TAURI_BINARY" --route "$VERIFY_ROUTE" >/dev/null 2>&1 || true
  sleep 1
fi

osascript -e "tell application \"System Events\" to set frontmost of process \"$PROCESS_NAME\" to true" >/dev/null
sleep 1
screencapture -x -l"$WINDOW_ID" "$SCREENSHOT_PATH"

SIZE="$(sips -g pixelWidth -g pixelHeight "$SCREENSHOT_PATH" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd x -)"

cat <<EOF
Tauri chat UI verification artifact written.

Server health: $HEALTH_PATH
Window id:     $WINDOW_ID
Route:         ${VERIFY_ROUTE:-current}
Screenshot:   $SCREENSHOT_PATH
Image size:   $SIZE

Open the screenshot and compare against macOS source-of-truth surfaces:
- session transcript renders user/assistant turns
- tool-call groups and plan/todo sections are visible when present
- composer controls match macOS for attachments, goal mode, plan mode, stop/send, and questions
- for tool-call parity, prefer a session route with ?verify=expanded
- for plan/todo parity, use CODEVISOR_VERIFY_ROUTE='/verify/chat-parity'
- for composer/question parity, use CODEVISOR_VERIFY_ROUTE='/verify/chat-composer'
EOF
