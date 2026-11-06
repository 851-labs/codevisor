#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/github-api.sh"

bench_workflows='^Screen Sharing Bench'
briefest_bench_s=180
job="$(github_api "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT/jobs" |
  jq -c '.jobs[] | select(.name == "gate") | {created_at, started_at}')"
created="$(jq -r .created_at <<<"$job")"
started="$(jq -r .started_at <<<"$job")"
waited=$(( $(/bin/date -juf %Y-%m-%dT%H:%M:%SZ "$started" +%s) - $(/bin/date -juf %Y-%m-%dT%H:%M:%SZ "$created" +%s) ))
overlapping="$(github_api "repos/$GITHUB_REPOSITORY/actions/runs?created=%3C$started&per_page=50" |
  jq -r ".workflow_runs[] | select(.name | test(\"$bench_workflows\")) | select(.id != $GITHUB_RUN_ID)
    | select(.status != \"completed\" or .updated_at > \"$created\")
    | select(.status != \"completed\" or (.updated_at | fromdate) - (.run_started_at | fromdate) > $briefest_bench_s)
    | \"[\(.name) run \(.run_number)](\(.html_url))\"")"

echo
if [[ -n "$overlapping" ]]; then
  echo "The gate waited $((waited / 60)) min for tamale; these bench runs were active meanwhile: $(paste -sd, - <<<"$overlapping")."
else
  echo "The gate waited $((waited / 60)) min for tamale; no other bench run was active."
fi
