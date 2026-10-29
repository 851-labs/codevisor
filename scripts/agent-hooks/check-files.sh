#!/usr/bin/env bash
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd -P)"

files=()
for path in "$@"; do
  [ -f "$path" ] || continue
  file="$(realpath "$path")"
  case "$file" in
    "$root"/*) files+=("${file#"$root"/}") ;;
  esac
done
[ ${#files[@]} -gt 0 ] || exit 0
cd "$root" || exit 0

status=0
report() {
  [ -z "$1" ] && return
  printf '%s\n' "$1"
  status=1
}

for file in "${files[@]}"; do
  case "$file" in
    *.ts | *.tsx | *.mts | *.cts | *.js | *.jsx | *.mjs | *.cjs)
      node_modules/.bin/oxfmt -c .oxfmtrc.json --disable-nested-config --write "$file" >/dev/null 2>&1
      output=$(node_modules/.bin/oxlint -c .oxlintrc.json --disable-nested-config --deny-warnings \
        --report-unused-disable-directives-severity=error --no-error-on-unmatched-pattern \
        "$file" 2>&1) || report "$output"
      ;;
    *.swift)
      swift format format --in-place "$file" >/dev/null 2>&1
      report "$(swift format lint --strict "$file" 2>&1)"
      ;;
  esac
done
exit $status
