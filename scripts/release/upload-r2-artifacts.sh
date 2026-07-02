#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/release/upload-r2-artifacts.sh <version> <artifact-dir>

Uploads Homebrew release artifacts to the HerdMan R2 bucket. Requires Wrangler
auth via CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
artifact_dir="${2:-}"

if [[ -z "$version" || -z "$artifact_dir" ]]; then
  usage >&2
  exit 1
fi

if ! command -v wrangler >/dev/null 2>&1; then
  echo "wrangler is required to upload R2 artifacts" >&2
  exit 1
fi

bucket="${R2_BUCKET:-herdman}"
prefix="${R2_PREFIX:-releases/herdman}"
cache_control="${R2_CACHE_CONTROL:-public, max-age=31536000, immutable}"

shopt -s nullglob
artifacts=("$artifact_dir"/*.zip "$artifact_dir"/*.tar.gz "$artifact_dir"/*.dmg)
shopt -u nullglob

if [[ "${#artifacts[@]}" -eq 0 ]]; then
  echo "No .zip, .tar.gz, or .dmg release artifacts found in $artifact_dir" >&2
  exit 1
fi

for artifact in "${artifacts[@]}"; do
  name="$(basename "$artifact")"
  case "$name" in
    *.zip)
      content_type="application/zip"
      ;;
    *.tar.gz)
      content_type="application/gzip"
      ;;
    *.dmg)
      content_type="application/x-apple-diskimage"
      ;;
    *)
      content_type="application/octet-stream"
      ;;
  esac

  wrangler r2 object put "$bucket/$prefix/v$version/$name" \
    --file "$artifact" \
    --content-type "$content_type" \
    --cache-control "$cache_control" \
    --remote
done

# The manifest the app and server update checks read (the GitHub repository is
# private, so the bucket is the one public source of release truth). Uploaded
# last so it never points at a partially uploaded release, and with a short
# cache so new releases are visible promptly.
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
printf '{"version":"%s"}\n' "$version" > "$manifest"
wrangler r2 object put "$bucket/$prefix/latest.json" \
  --file "$manifest" \
  --content-type "application/json" \
  --cache-control "${R2_LATEST_CACHE_CONTROL:-public, max-age=60}" \
  --remote
