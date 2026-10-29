#!/usr/bin/env bash
set -euo pipefail

branch=benchmark-results
action=${1:-}
scripts="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
attempts=3

usage() {
  echo "Usage: $0 index <index.jsonl> | publish <report.json> <published.json>" >&2
  exit 2
}

branch_exists() {
  local status=0
  git ls-remote --exit-code -q origin "refs/heads/$branch" >/dev/null || status=$?
  ((status == 0 || status == 2)) || { echo "can't reach origin to look for $branch" >&2; exit 1; }
  ((status == 0))
}

fetch_index() {
  local output=$1
  if branch_exists; then
    git fetch -q origin "$branch"
    git show FETCH_HEAD:index.jsonl >"$output"
  else
    : >"$output"
  fi
}

checkout() {
  local worktree=$1
  git worktree remove --force "$worktree" 2>/dev/null || true
  if branch_exists; then
    git fetch -q origin "$branch"
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
  done
  return 1
}

case "$action" in
  index) [[ $# -eq 2 ]] || usage; fetch_index "$2" ;;
  publish) [[ $# -eq 3 ]] || usage; publish "$2" "$3" ;;
  *) usage ;;
esac
