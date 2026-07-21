#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/download-github-artifact.sh <run-id> <artifact-name> <destination> [wait-seconds]

Downloads and extracts one GitHub Actions artifact using the REST API. This
keeps release jobs portable to self-hosted runners that do not have the GitHub
CLI installed. Requires node, curl, GH_TOKEN, GITHUB_API_URL, and
GITHUB_REPOSITORY.
EOF
}

run_id="${1:-}"
artifact_name="${2:-}"
destination="${3:-}"
wait_seconds="${4:-0}"

if [[ -z "$run_id" || -z "$artifact_name" || -z "$destination" ]]; then
  usage
  exit 1
fi
if [[ "$wait_seconds" == *[!0-9]* ]]; then
  echo "wait-seconds must be a non-negative integer" >&2
  exit 1
fi
if [[ -z "${GH_TOKEN:-}" || -z "${GITHUB_API_URL:-}" || -z "${GITHUB_REPOSITORY:-}" ]]; then
  echo "GH_TOKEN, GITHUB_API_URL, and GITHUB_REPOSITORY are required" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  echo "node and curl are required" >&2
  exit 1
fi

api_url="$GITHUB_API_URL/repos/$GITHUB_REPOSITORY/actions/runs/$run_id/artifacts?per_page=100"
started_at=$SECONDS
archive_url=""
while true; do
  response="$(curl --fail --silent --show-error \
    --header "Authorization: Bearer $GH_TOKEN" \
    --header "Accept: application/vnd.github+json" \
    --header "X-GitHub-Api-Version: 2022-11-28" \
    "$api_url")"
  archive_url="$(printf '%s' "$response" | node -e '
    const fs = require("node:fs");
    const name = process.argv[1];
    const body = JSON.parse(fs.readFileSync(0, "utf8"));
    const artifact = body.artifacts?.find((item) => item.name === name && !item.expired);
    if (artifact?.archive_download_url) process.stdout.write(artifact.archive_download_url);
  ' "$artifact_name")"
  if [[ -n "$archive_url" ]]; then
    break
  fi
  if (( SECONDS - started_at >= wait_seconds )); then
    echo "Artifact $artifact_name was not available in run $run_id after ${wait_seconds}s." >&2
    exit 1
  fi
  echo "Artifact $artifact_name is not ready; retrying in 10s."
  sleep 10
done

archive="$(mktemp "${RUNNER_TEMP:-/tmp}/codevisor-artifact.XXXXXX")"
trap 'rm -f "$archive"' EXIT
curl --fail --silent --show-error --location \
  --header "Authorization: Bearer $GH_TOKEN" \
  --header "Accept: application/vnd.github+json" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "$archive_url" \
  --output "$archive"
mkdir -p "$destination"
if command -v ditto >/dev/null 2>&1; then
  ditto -x -k "$archive" "$destination"
elif command -v unzip >/dev/null 2>&1; then
  unzip -q "$archive" -d "$destination"
else
  echo "ditto or unzip is required to extract GitHub artifacts" >&2
  exit 1
fi
echo "Downloaded $artifact_name from run $run_id into $destination."
