#!/usr/bin/env bash
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 0
cat >/dev/null
state="$(git rev-parse --git-path agent-hooks-agy-report)"

report=$({ git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u |
  grep -E '\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|swift)$' | tr '\n' '\0' | xargs -0 scripts/agent-hooks/check-files.sh)
if [ -z "$report" ]; then
  rm -f "$state"
  echo '{}'
  exit 0
fi
if [ "$report" = "$(cat "$state" 2>/dev/null)" ]; then
  echo '{}'
  exit 0
fi
printf '%s' "$report" >"$state"
jq -n --arg m "Formatted your changed files. Lint errors to fix now:
$report" '{injectSteps: [{ephemeralMessage: $m}]}'
