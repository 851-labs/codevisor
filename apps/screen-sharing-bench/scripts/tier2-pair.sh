#!/usr/bin/env bash
set -euo pipefail

: "${TIER2_PAIR_POLL_S:=15}"
: "${TIER2_PAIR_CONFIRM_S:=45}"
output=${GITHUB_OUTPUT:-/dev/null}

say() {
  echo "$(date '+%H:%M:%S') $*" >&2
}

polls() {
  echo $((($1 + $2 - 1) / $2))
}

peer_state() {
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100" |
    jq -r --arg peer "$1" '
      def named($name): .name == $name or (.name | endswith(" / " + $name));
      ([.jobs[] | select(named($peer))][0]) as $first
      | ([.jobs[] | select(named($peer + "-retry"))][0]) as $retry
      | if $retry != null and $retry.conclusion == "skipped" then "\($retry.id) gone"
        elif $retry != null then "\($retry.id) \($retry.status)"
        elif $first == null then "none missing"
        elif $first.status == "completed" then "\($first.id) rejoining"
        else "\($first.id) \($first.status)" end'
}

pair() {
  local peer=$1 hold_s=$2 on_timeout=$3
  local hold confirm waited=0 seen=0 seen_job="" state job status
  hold=$(polls "$hold_s" "$TIER2_PAIR_POLL_S")
  confirm=$(polls "$TIER2_PAIR_CONFIRM_S" "$TIER2_PAIR_POLL_S")
  while :; do
    state=$(peer_state "$peer") || state="none unknown"
    read -r job status <<<"$state"
    case "$status" in
      in_progress)
        [[ "$job" == "$seen_job" ]] || seen=0 seen_job=$job
        seen=$((seen + 1))
        if ((seen > confirm)); then
          say "the $peer job is running; paired"
          echo "paired=true" >>"$output"
          return 0
        fi
        ;;
      gone)
        say "the $peer job ended without running the bench, so there is nothing to pair with"
        return 1
        ;;
      *)
        seen=0
        if ((waited >= hold)); then
          if [[ "$on_timeout" == yield ]]; then
            say "the $peer job was still $status after ${hold_s}s; giving up this runner and rejoining the queue"
            echo "paired=false" >>"$output"
            return 0
          fi
          say "the $peer job was still $status after ${hold_s}s"
          return 1
        fi
        ;;
    esac
    waited=$((waited + 1))
    sleep "$TIER2_PAIR_POLL_S"
  done
}

usage() {
  echo "Usage: $0 pair <peer-job> <hold-s> <yield|fail>" >&2
  exit 2
}

[[ "${1:-}" == pair && $# == 4 && "$4" =~ ^(yield|fail)$ ]] || usage
pair "$2" "$3" "$4"
