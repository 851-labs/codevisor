#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: publish-update-artifacts.sh <alpha|stable> <version> <tag> <build-number> <artifact-dir> <release-notes>" >&2
}

channel="${1:-}"
version="${2:-}"
tag="${3:-}"
build_number="${4:-}"
artifact_dir="${5:-}"
release_notes="${6:-}"
if [[ "$channel" != alpha && "$channel" != stable ]] || [[ -z "$version" || -z "$tag" || -z "$build_number" || -z "$artifact_dir" || -z "$release_notes" ]]; then
  usage
  exit 1
fi
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY R2_S3_API_ENDPOINT SPARKLE_PRIVATE_KEY; do
  if [[ -z "${!variable:-}" ]]; then
    echo "$variable is required" >&2
    exit 1
  fi
done

export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}"
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"
bucket="${R2_BUCKET:-herdman}"
origin="${CODEVISOR_UPDATE_ORIGIN:-https://updates.codevisor.dev}"
prefix="updates/$tag"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
sparkle_public_key="${CODEVISOR_SPARKLE_PUBLIC_KEY:-1FsNm9QTvUciP2sETZFfeTkWHCPjRNU6mEQ1wzqQz2k=}"

notes_name="release-notes-$tag.md"
aws s3 cp "$release_notes" "s3://$bucket/$prefix/$notes_name" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type text/markdown \
  --cache-control "public, max-age=31536000, immutable"

for arch in arm64 x64; do
  archive="$artifact_dir/Codevisor-macOS-$arch.zip"
  [[ -f "$archive" ]] || { echo "Missing $archive" >&2; exit 1; }
  signature="$(node scripts/release/sign-sparkle-update.mjs "$archive" "$sparkle_public_key")"
  if [[ "$(uname -s)" == Darwin ]]; then
    length="$(stat -f %z "$archive")"
  else
    length="$(stat -c %s "$archive")"
  fi
  name="$(basename "$archive")"
  aws s3 cp "$archive" "s3://$bucket/$prefix/$name" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type application/zip \
    --cache-control "public, max-age=31536000, immutable"

  old_feed="$work_dir/appcast-$arch-old.xml"
  new_feed="$work_dir/appcast-$arch.xml"
  curl --fail --silent --show-error "$origin/appcast-$arch.xml" --output "$old_feed" || true
  node scripts/release/update-appcast.mjs \
    --input "$old_feed" \
    --output "$new_feed" \
    --channel "$channel" \
    --version "$version" \
    --build "$build_number" \
    --url "$origin/$prefix/$name" \
    --signature "$signature" \
    --length "$length" \
    --release-notes-url "https://github.com/${GITHUB_REPOSITORY:-851-labs/codevisor}/releases/tag/$tag"
  aws s3 cp "$new_feed" "s3://$bucket/appcast-$arch.xml" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type application/xml \
    --cache-control "public, max-age=60"
done

if [[ "$channel" == stable ]]; then
  for target in linux-arm64 linux-x64 darwin-arm64 darwin-x64; do
    archive="$artifact_dir/codevisor-server-$target.tar.gz"
    checksum="$archive.sha256"
    [[ -f "$archive" && -f "$checksum" ]] || { echo "Missing server artifact for $target" >&2; exit 1; }
    for file in "$archive" "$checksum"; do
      content_type=application/gzip
      [[ "$file" == *.sha256 ]] && content_type=text/plain
      aws s3 cp "$file" "s3://$bucket/$prefix/$(basename "$file")" \
        --endpoint-url "$R2_S3_API_ENDPOINT" \
        --content-type "$content_type" \
        --cache-control "public, max-age=31536000, immutable"
    done
  done
  manifest="$work_dir/stable.json"
  jq -n \
    --arg version "$version" \
    --arg releasePageURL "https://github.com/${GITHUB_REPOSITORY:-851-labs/codevisor}/releases/tag/$tag" \
    --arg origin "$origin/$prefix" \
    '{
      version: $version,
      releasePageURL: $releasePageURL,
      targets: (["linux-arm64","linux-x64","darwin-arm64","darwin-x64"] | map({
        key: .,
        value: {
          archiveURL: ($origin + "/codevisor-server-" + . + ".tar.gz"),
          checksumURL: ($origin + "/codevisor-server-" + . + ".tar.gz.sha256")
        }
      }) | from_entries)
    }' > "$manifest"
  aws s3 cp "$manifest" "s3://$bucket/server/stable.json" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type application/json \
    --cache-control "public, max-age=60"
fi
