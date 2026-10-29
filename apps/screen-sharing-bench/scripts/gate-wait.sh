#!/usr/bin/env bash
set -euo pipefail

bench_workflows='^Screen Sharing Bench'
job="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs" \
  --jq '.jobs[] | select(.name == "gate") | {created_at, started_at}')"
created="$(jq -r .created_at <<<"$job")"
started="$(jq -r .started_at <<<"$job")"
waited=$(( $(date -juf %Y-%m-%dT%H:%M:%SZ "$started" +%s) - $(date -juf %Y-%m-%dT%H:%M:%SZ "$created" +%s) ))
overlapping="$(gh api "repos/$GITHUB_REPOSITORY/actions/runs?created=<$started&per_page=50" \
  --jq ".workflow_runs[] | select(.name | test(\"$bench_workflows\")) | select(.id != $GITHUB_RUN_ID)
    | select(.status != \"completed\" or .updated_at > \"$created\") | \"[\(.name) run \(.run_number)](\(.html_url))\"")"

echo
if [[ -n "$overlapping" ]]; then
  echo "The gate waited $((waited / 60)) min for tamale; these bench runs were active meanwhile: $(paste -sd, - <<<"$overlapping")."
else
  echo "The gate waited $((waited / 60)) min for tamale; no other bench run was active."
fi
