#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/github-api.sh"
[[ -n "${GH_TOKEN:-}" ]] || { echo "GH_TOKEN must be set to read the run's jobs" >&2; exit 2; }

: "${TIER2_PAIR_POLL_S:=30}"
: "${TIER2_PAIR_CONFIRM_S:=60}"
output=${GITHUB_OUTPUT:-/dev/null}

say() {
  echo "$(date '+%H:%M:%S') $*" >&2
}

polls() {
  echo $((($1 + $2 - 1) / $2))
}

peer_state() {
  github_api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs?per_page=100" |
    jq -r --arg peer "$1" --arg runner "$RUNNER_NAME" --arg own "$GITHUB_JOB" '
      ([.jobs[] | select(.status == "in_progress" and .runner_name == $runner)][0].name // null) as $own_name
      | if $own_name == null or ($own_name | endswith($own) | not) then "none unknown"
        else ($own_name | .[0:length - ($own | length)]) as $prefix
        | ([.jobs[] | select(.name == $prefix + $peer)][0]) as $first
        | ([.jobs[] | select(.name == $prefix + $peer + "-retry")][0]) as $retry
        | if $retry != null and $retry.status == "completed" then "\($retry.id) gone"
          elif $retry != null then "\($retry.id) \($retry.status)"
          elif $first == null then "none missing"
          elif $first.status == "completed" and $first.conclusion != "success" then "\($first.id) gone"
          elif $first.status == "completed" then "\($first.id) rejoining"
          else "\($first.id) \($first.status)" end
        end'
}

peer=${1:-} hold_s=${2:-} on_timeout=${3:-}
[[ $# == 3 && "$hold_s" =~ ^[0-9]+$ && "$on_timeout" =~ ^(yield|fail)$ ]] || {
  echo "Usage: $0 <peer-job> <hold-s> <yield|fail>" >&2
  exit 2
}
hold=$(polls "$hold_s" "$TIER2_PAIR_POLL_S")
confirm=$(polls "$TIER2_PAIR_CONFIRM_S" "$TIER2_PAIR_POLL_S")
waited=0 seen=0 seen_job=""
while :; do
  state=$(peer_state "$peer") || state="none unknown"
  read -r job status <<<"$state"
  case "$status" in
    unknown)
      ((waited < 2 * hold)) || {
        say "couldn't read the $peer job's state from the GitHub API for ${hold_s}s past the hold"
        exit 1
      }
      ;;
    in_progress)
      [[ "$job" == "$seen_job" ]] || seen=0 seen_job=$job
      seen=$((seen + 1))
      if ((seen > confirm)); then
        say "the $peer job is running; paired"
        echo "paired=true" >>"$output"
        exit 0
      fi
      ;;
    gone)
      say "the $peer job ended without running the bench, so there is nothing to pair with"
      exit 1
      ;;
    *)
      seen=0
      if ((waited >= hold)); then
        if [[ "$on_timeout" == yield ]]; then
          say "the $peer job was still $status after ${hold_s}s; giving up this runner and rejoining the queue"
          echo "paired=false" >>"$output"
          exit 0
        fi
        say "the $peer job was still $status after ${hold_s}s"
        exit 1
      fi
      ;;
  esac
  waited=$((waited + 1))
  sleep "$TIER2_PAIR_POLL_S"
done
