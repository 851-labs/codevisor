#!/usr/bin/env bash
set -euo pipefail

branch=benchmark-results
action=${1:-}
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
attempts=3
network_attempts=4
network_pause_s=20

usage() {
  echo "Usage: $0 index <index.jsonl> | publish <report.json> <published.json>" >&2
  exit 2
}

export GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=60

fetch_branch() {
  local try errors
  branch_missing=0
  for try in $(seq 1 "$network_attempts"); do
    errors="$(git fetch -q origin "$branch" 2>&1)" && return 0
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
  if ((branch_missing)); then : >"$output"; else git show FETCH_HEAD:index.jsonl >"$output"; fi
}

checkout() {
  local worktree=$1
  git worktree remove --force "$worktree" 2>/dev/null || true
  fetch_branch
  if ((branch_missing == 0)); then
    git worktree add -q --detach "$worktree" FETCH_HEAD
  else
    git worktree add -q --detach "$worktree"
    git -C "$worktree" checkout -q --orphan "$branch-new"
    git -C "$worktree" rm -rfq .
  fi
}

commit() {
  local worktree=$1 report=$2
  "$scripts/run-installed.sh" record --report "$report" --results "$worktree" >"$worktree.recorded.json"
  git -C "$worktree" add -A
  git -C "$worktree" -c user.name="github-actions[bot]" \
    -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -qm "Record $(plutil -extract report raw "$worktree.recorded.json")"
}

publish() {
  local report=$1 published=$2
  local worktree="${RUNNER_TEMP:-/tmp}/$branch"
  for attempt in $(seq 1 "$attempts"); do
    checkout "$worktree"
    commit "$worktree" "$report"
    if git -C "$worktree" push -q origin "HEAD:refs/heads/$branch"; then
      plutil -insert commit -string "$(git -C "$worktree" rev-parse HEAD)" -o "$published" "$worktree.recorded.json"
      git worktree remove --force "$worktree"
      return 0
    fi
    echo "pushing $branch failed (attempt $attempt)" >&2
    ((attempt == attempts)) || sleep $((network_pause_s * attempt))
  done
  return 1
}

case "$action" in
  index) [[ $# -eq 2 ]] || usage; fetch_index "$2" ;;
  publish) [[ $# -eq 3 ]] || usage; publish "$2" "$3" ;;
  *) usage ;;
esac
