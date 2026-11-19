#!/usr/bin/env bash
set -euo pipefail

action=${1:-}
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_bundle_id=com.851labs.HerdMan
server_agent=com.851labs.Codevisor.ServerAgent
record="${CODEVISOR_BENCH_REOPEN_RECORD:-$HOME/Library/Application Support/CodevisorBench/reopen-apps.txt}"

say_server() {
  local pid
  pid=$(launchctl print "gui/$(id -u)/$server_agent" 2>/dev/null | awk '$1 == "pid" { print $3 }') || true
  echo "Codevisor's server ($server_agent) $1: pid ${pid:-none}"
}

open_outside_the_job() {
  env -i /usr/bin/open "$1"
}

quit() {
  mkdir -p "$(dirname "$record")"
  say_server "before the app quits"
  CODEVISOR_BENCH_BACKGROUND=1 "$scripts/run-installed.sh" quit-apps --bundle-ids "$app_bundle_id" --record "$record"
  say_server "after the app quit"
}

reopen() {
  [[ -s "$record" ]] || { echo "No benchmark quit the Codevisor app; nothing to reopen"; return 0; }
  local app
  while IFS= read -r app; do
    open_outside_the_job "$app"
    echo "Reopened $app"
  done <"$record"
  rm -f "$record"
  say_server "after the app reopened"
}

case "$action" in
  quit | reopen) "$action" ;;
  *) echo "Usage: $0 quit|reopen" >&2; exit 2 ;;
esac
