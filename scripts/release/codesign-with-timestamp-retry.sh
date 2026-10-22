#!/usr/bin/env bash
set -uo pipefail

attempts=4
delay=15
unavailable="The timestamp service is not available."

for ((attempt = 1; ; attempt++)); do
  output="$(codesign "$@" 2>&1)"
  status=$?
  [[ -z "$output" ]] || echo "$output" >&2
  [[ $status -ne 0 ]] || exit 0
  if [[ "$output" != *"$unavailable"* || $attempt -ge $attempts ]]; then
    exit "$status"
  fi
  echo "Apple's timestamp service was unavailable (attempt $attempt of $attempts); retrying in ${delay}s" >&2
  sleep "$delay"
  delay=$((delay * 2))
done
