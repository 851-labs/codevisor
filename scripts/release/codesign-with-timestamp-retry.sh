#!/usr/bin/env bash
set -uo pipefail

attempts=4
delay=15
timestamp_outages=(
  "The timestamp service is not available."
  "A timestamp was expected but was not found."
)

is_timestamp_outage() {
  local outage
  for outage in "${timestamp_outages[@]}"; do
    [[ "$1" == *"$outage"* ]] && return 0
  done
  return 1
}

for ((attempt = 1; ; attempt++)); do
  output="$(codesign "$@" 2>&1)"
  status=$?
  [[ -z "$output" ]] || echo "$output" >&2
  [[ $status -ne 0 ]] || exit 0
  if ! is_timestamp_outage "$output" || [[ $attempt -ge $attempts ]]; then
    exit "$status"
  fi
  echo "Apple's timestamp service was unavailable (attempt $attempt of $attempts); retrying in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
done
