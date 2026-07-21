#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
usage: scripts/release/upload-r2-artifacts.sh <version> <artifact-dir>

Publishes the one-time compatibility bridge to the existing R2 bucket via the
S3 API. Once bridge.json exists this command is a no-op: old clients must keep
seeing the GitHub-aware bridge forever, while all newer clients use GitHub.

Requires R2_BRIDGE_MODE=1, the aws CLI, and R2 S3 credentials in
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, and R2_S3_API_ENDPOINT.
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

if [[ "${R2_BRIDGE_MODE:-}" != 1 ]]; then
  echo "Refusing to mutate the frozen R2 feed without R2_BRIDGE_MODE=1." >&2
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
bridge_key="$prefix/bridge.json"

if aws s3api head-object \
  --bucket "$bucket" \
  --key "$bridge_key" \
  --endpoint-url "$R2_S3_API_ENDPOINT" >/dev/null 2>&1; then
  echo "R2 compatibility bridge already exists; leaving it unchanged."
  exit 0
fi

shopt -s nullglob
artifacts=(
  "$artifact_dir"/Codevisor-*.zip
  "$artifact_dir"/Codevisor-*.zip.sha256
  "$artifact_dir"/Codevisor*.dmg
  "$artifact_dir"/Codevisor*.dmg.sha256
  "$artifact_dir"/codevisor-server-*.tar.gz
  "$artifact_dir"/codevisor-server-*.tar.gz.sha256
)
shopt -u nullglob

if [[ "${#artifacts[@]}" -eq 0 ]]; then
  echo "No release artifacts found in $artifact_dir" >&2
  exit 1
fi

for artifact in "${artifacts[@]}"; do
  name="$(basename "$artifact")"
  case "$name" in
    *.zip)
      content_type="application/zip"
      ;;
    *.sha256)
      content_type="text/plain"
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
    Codevisor-macOS.zip.sha256) legacy_name="HerdMan-macOS.zip.sha256" ;;
    Codevisor.dmg) legacy_name="HerdMan.dmg" ;;
    Codevisor.dmg.sha256) legacy_name="HerdMan.dmg.sha256" ;;
    codevisor-server-*.tar.gz) legacy_name="herdman-${name#codevisor-}" ;;
    codevisor-server-*.tar.gz.sha256) legacy_name="herdman-${name#codevisor-}" ;;
  esac
  if [[ -n "$legacy_name" ]]; then
    aws s3 cp "$artifact" "s3://$bucket/$legacy_prefix/v$version/$legacy_name" \
      --endpoint-url "$R2_S3_API_ENDPOINT" \
      --content-type "$content_type" \
      --cache-control "$cache_control"
  fi
done

# Upload both manifests last so no old client can discover a partial bridge.
# The immutable marker is last of all and prevents future stable releases from
# advancing either feed.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
manifest="$work_dir/latest.json"
printf '{"version":"%s"}\n' "$version" > "$manifest"
aws s3 cp "$manifest" "s3://$bucket/$prefix/latest.json" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type "application/json" \
  --cache-control "${R2_LATEST_CACHE_CONTROL:-public, max-age=60}"
aws s3 cp "$manifest" "s3://$bucket/$legacy_prefix/latest.json" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type "application/json" \
  --cache-control "${R2_LATEST_CACHE_CONTROL:-public, max-age=60}"

bridge="$work_dir/bridge.json"
printf '{"version":"%s","source":"github","frozen":true}\n' "$version" > "$bridge"
aws s3 cp "$bridge" "s3://$bucket/$bridge_key" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type "application/json" \
  --cache-control "$cache_control"
echo "R2 compatibility feeds are frozen at Codevisor $version."
