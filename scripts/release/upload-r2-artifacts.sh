#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/release/upload-r2-artifacts.sh <version> <artifact-dir>

Uploads Codevisor release artifacts to the existing R2 bucket via the S3 API,
which multipart-uploads large files (wrangler caps out at 300 MiB). Requires
the aws CLI plus R2 S3 credentials in AWS_ACCESS_KEY_ID,
AWS_SECRET_ACCESS_KEY, and R2_S3_API_ENDPOINT.
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

if ! command -v aws >/dev/null 2>&1; then
  echo "the aws CLI is required to upload R2 artifacts" >&2
  exit 1
fi

if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" || -z "${R2_S3_API_ENDPOINT:-}" ]]; then
  echo "AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and R2_S3_API_ENDPOINT are required for R2 uploads" >&2
  exit 1
fi

# R2 wants the literal region "auto", and aws CLI >= 2.23 defaults to CRC32
# request checksums that R2's S3 API rejects.
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

bucket="${R2_BUCKET:-herdman}"
prefix="${R2_PREFIX:-releases/codevisor}"
legacy_prefix="${R2_LEGACY_PREFIX:-releases/herdman}"
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

  aws s3 cp "$artifact" "s3://$bucket/$prefix/v$version/$name" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type "$content_type" \
    --cache-control "$cache_control"

  # Existing HerdMan apps and standalone servers must be able to discover and
  # download this first Codevisor update. Publish branded aliases under the
  # former prefix until those clients have crossed the rename boundary.
  legacy_name=""
  case "$name" in
    Codevisor-macOS.zip) legacy_name="HerdMan-macOS.zip" ;;
    Codevisor.dmg) legacy_name="HerdMan.dmg" ;;
    codevisor-server-*.tar.gz) legacy_name="herdman-${name#codevisor-}" ;;
  esac
  if [[ -n "$legacy_name" ]]; then
    aws s3 cp "$artifact" "s3://$bucket/$legacy_prefix/v$version/$legacy_name" \
      --endpoint-url "$R2_S3_API_ENDPOINT" \
      --content-type "$content_type" \
      --cache-control "$cache_control"
  fi
done

# The manifest the app and server update checks read (the GitHub repository is
# private, so the bucket is the one public source of release truth). Uploaded
# last so it never points at a partially uploaded release, and with a short
# cache so new releases are visible promptly.
manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
printf '{"version":"%s"}\n' "$version" > "$manifest"
aws s3 cp "$manifest" "s3://$bucket/$prefix/latest.json" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type "application/json" \
  --cache-control "${R2_LATEST_CACHE_CONTROL:-public, max-age=60}"
aws s3 cp "$manifest" "s3://$bucket/$legacy_prefix/latest.json" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type "application/json" \
  --cache-control "${R2_LATEST_CACHE_CONTROL:-public, max-age=60}"
