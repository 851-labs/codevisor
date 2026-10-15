#!/usr/bin/env bash
set -euo pipefail

targets=("$@")
[[ ${#targets[@]} -gt 0 ]] || targets=(croissant@croissants-mac-mini tamale@tamales-mac-mini)
source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
label=com.851labs.runner-metrics

for target in "${targets[@]}"; do
  echo "Deploying to $target"
  ssh "$target" 'mkdir -p ~/runner-metrics/data ~/Library/LaunchAgents'
  plist="$(mktemp)"
  sed "s|HOME_DIR|/Users/${target%@*}|g" "$source_dir/$label.plist" >"$plist"
  scp -q "$source_dir/runner_metrics.py" "$source_dir/index.html" "${target}:runner-metrics/"
  scp -q "$plist" "${target}:Library/LaunchAgents/$label.plist"
  rm "$plist"
  ssh "$target" "LABEL=$label bash -s" <<'REMOTE'
set -euo pipefail
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
plutil -lint -s "$plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
for _ in $(seq 20); do
  curl -sf -o /dev/null http://127.0.0.1:9187/api/metrics?since=0 && { echo "  serving on :9187"; exit 0; }
  sleep 0.5
done
echo "  collector did not start; see ~/runner-metrics/collector.log" >&2
exit 1
REMOTE
done

echo "Dashboard (tailnet only): http://croissants-mac-mini:9187"
