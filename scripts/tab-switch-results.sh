#!/usr/bin/env bash
set -euo pipefail

branch=benchmark-results
index=tab-switch/index.jsonl
action=${1:-}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
attempts=3
network_attempts=4
network_pause_s=20

usage() {
  echo "Usage: $0 index <index.jsonl> | publish <summary.json> <run id> <commit> <ISO date>" >&2
  exit 2
}

export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60

fetch_branch() {
  local try errors
  branch_missing=0
  for try in $(seq 1 "$network_attempts"); do
    errors="$(git -C "$root" fetch -q origin "$branch" 2>&1)" && return 0
    if [[ "$errors" == *"couldn't find remote ref"* ]]; then
      branch_missing=1
      return 0
    fi
    echo "fetching $branch failed (attempt $try of $network_attempts): $errors" >&2
    ((try == network_attempts)) || sleep $((network_pause_s * try))
  done
  exit 1
}

fetch_index() {
  local output=$1
  fetch_branch
  if ((branch_missing)) || ! git -C "$root" cat-file -e "FETCH_HEAD:$index" 2>/dev/null; then
    : >"$output"
  else
    git -C "$root" show "FETCH_HEAD:$index" >"$output"
  fi
}

checkout() {
  local worktree=$1
  git -C "$root" worktree remove --force "$worktree" 2>/dev/null || true
  git -C "$root" worktree prune
  fetch_branch
  if ((branch_missing == 0)); then
    git -C "$root" worktree add -q --detach "$worktree" FETCH_HEAD
  else
    git -C "$root" worktree add -q --detach "$worktree"
    git -C "$worktree" checkout -q --orphan "$branch-new"
    git -C "$worktree" rm -rfq .
  fi
}

publish() {
  local summary=$1 id=$2 sha=$3 date=$4
  local worktree="${RUNNER_TEMP:-/tmp}/$branch-tab-switch"
  for attempt in $(seq 1 "$attempts"); do
    checkout "$worktree"
    mkdir -p "$worktree/$(dirname "$index")"
    node "$root/scripts/tab-switch-gate.mjs" record --index "$worktree/$index" --run "$summary" \
      --id "$id" --sha "$sha" --date "$date"
    git -C "$worktree" add -A
    if git -C "$worktree" diff --cached --quiet; then
      echo "run $id is already recorded" >&2
      git -C "$root" worktree remove --force "$worktree"
      return 0
    fi
    git -C "$worktree" -c user.name="github-actions[bot]" \
      -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
      commit -qm "Record tab switch run $id"
    if git -C "$worktree" push -q origin "HEAD:refs/heads/$branch"; then
      git -C "$root" worktree remove --force "$worktree"
      return 0
    fi
    echo "pushing $branch failed (attempt $attempt)" >&2
    ((attempt == attempts)) || sleep $((network_pause_s * attempt))
  done
  return 1
}

case "$action" in
  index) [[ $# -eq 2 ]] || usage; fetch_index "$2" ;;
  publish) [[ $# -eq 5 ]] || usage; publish "$2" "$3" "$4" "$5" ;;
  *) usage ;;
esac
