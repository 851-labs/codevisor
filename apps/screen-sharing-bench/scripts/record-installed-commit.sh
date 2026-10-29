#!/usr/bin/env bash
set -euo pipefail

results=${1:-}
[[ -n "$results" ]] || { echo "Usage: $0 <results-directory>" >&2; exit 2; }
installed="${CODEVISOR_BENCH_APP:-$HOME/Applications/CodevisorBench.app}"

commit="$(plutil -extract CodevisorBenchCommit raw "$installed/Contents/Info.plist")"
echo "$commit" >"$results/installed-commit.txt"
if [[ -n "${GITHUB_SHA:-}" && "$commit" != "$GITHUB_SHA" ]]; then
  echo "::warning::$(hostname -s) has CodevisorBench.app from $commit, not $GITHUB_SHA; redeploy with scripts/deploy.sh"
fi
