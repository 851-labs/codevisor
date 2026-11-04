#!/usr/bin/env bash
set -euo pipefail

: "${TIER2_MINIS:=tamale,croissant}"
: "${TIER2_MINIS_POLL_S:=120}"
: "${TIER2_MINI_LABELS:=self-hosted,macOS,ARM64,codevisor-macos-arm64,tamale,croissant}"
: "${TIER2_PAIR_POLL_S:=15}"
: "${TIER2_PAIR_CONFIRM_S:=45}"
runs_api="repos/$GITHUB_REPOSITORY/actions/runs"
output=${GITHUB_OUTPUT:-/dev/null}

say() {
  echo "$(date '+%H:%M:%S') $*" >&2
}

polls() {
  echo $((($1 + $2 - 1) / $2))
}

minis_pattern() {
  echo "(^|-)(${TIER2_MINIS//,/|})$"
}

other_runs() {
  local status
  for status in in_progress queued; do
    gh api "$runs_api?status=$status&per_page=100" |
      jq -r --argjson own "$GITHUB_RUN_ID" '.workflow_runs[] | select(.id != $own) | .id' || return 1
  done
}

mini_jobs() {
  local runs run
  runs=$(other_runs) || return 1
  for run in $runs; do
    gh api "$runs_api/$run/jobs?filter=latest&per_page=100" |
      jq -r --arg minis "$(minis_pattern)" --arg labels "$TIER2_MINI_LABELS" '
      ($labels | ascii_downcase | split(",")) as $mini_labels
      | .jobs[]
      | ((.labels // []) | map(ascii_downcase)) as $wanted
      | select((.status == "in_progress" and ((.runner_name // "") | test($minis)))
        or (.status == "queued" and ($wanted | index("self-hosted")) and ($wanted - $mini_labels | length == 0)))
      | "\(.name), \(.status)\(if .runner_name then " on \(.runner_name)" else "" end): \(.html_url)"' || return 1
  done
}

wait_for_minis() {
  local patience_s=$1 left jobs
  left=$(polls "$patience_s" "$TIER2_MINIS_POLL_S")
  while :; do
    jobs=$(mini_jobs) || jobs="the GitHub API call failed"
    [[ -n "$jobs" ]] || { say "tamale and croissant are free"; return 0; }
    ((left > 0)) || { say "the minis were still busy after ${patience_s}s; starting anyway"; return 0; }
    say "waiting for the minis to be free of:"
    echo "$jobs" >&2
    left=$((left - 1))
    sleep "$TIER2_MINIS_POLL_S"
  done
}

peer_status() {
  gh api "$runs_api/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100" |
    jq -r --arg peer "$1" '[.jobs[] | select(.name == $peer or (.name | endswith(" / " + $peer)))][0].status // "missing"'
}

unpaired() {
  local on_timeout=$1 reason=$2
  if [[ "$on_timeout" == yield ]]; then
    say "$reason; releasing this runner so the pair can retry"
    echo "paired=false" >>"$output"
    return 0
  fi
  say "$reason"
  return 1
}

pair() {
  local peer=$1 hold_s=$2 on_timeout=$3
  local hold confirm waited=0 seen=0 status
  hold=$(polls "$hold_s" "$TIER2_PAIR_POLL_S")
  confirm=$(polls "$TIER2_PAIR_CONFIRM_S" "$TIER2_PAIR_POLL_S")
  while :; do
    status=$(peer_status "$peer") || status="unknown (the GitHub API call failed)"
    case "$status" in
      in_progress)
        seen=$((seen + 1))
        if ((seen > confirm)); then
          say "the $peer job is running; paired"
          echo "paired=true" >>"$output"
          return 0
        fi
        ;;
      completed)
        unpaired "$on_timeout" "the $peer job finished before pairing"
        return
        ;;
      *)
        seen=0
        ((waited < hold)) || {
          unpaired "$on_timeout" "the $peer job was still $status after ${hold_s}s"
          return
        }
        ;;
    esac
    waited=$((waited + 1))
    sleep "$TIER2_PAIR_POLL_S"
  done
}

usage() {
  echo "Usage: $0 wait-for-minis <patience-s> | pair <peer-job> <hold-s> <yield|fail>" >&2
  exit 2
}

case "${1:-}" in
  wait-for-minis)
    (($# == 2)) || usage
    wait_for_minis "$2"
    ;;
  pair)
    (($# == 4)) && [[ "$4" =~ ^(yield|fail)$ ]] || usage
    pair "$2" "$3" "$4"
    ;;
  *) usage ;;
esac
