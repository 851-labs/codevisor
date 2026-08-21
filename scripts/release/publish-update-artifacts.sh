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
repository="${GITHUB_REPOSITORY:-851-labs/codevisor}"
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
    --release-notes-url "$origin/$prefix/$notes_name" \
    --release-page-url "https://github.com/$repository/releases/tag/$tag" \
    --full-release-notes-url "https://github.com/$repository/releases"
  aws s3 cp "$new_feed" "s3://$bucket/appcast-$arch.xml" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type application/xml \
    --cache-control "public, max-age=60"
done

# Server archives and the per-channel manifest publish on BOTH channels:
# remote machines follow server/stable.json or server/alpha.json depending on
# the update channel the client requests. The manifest version carries the
# full tag version (alphas include their pre-release suffix) and the CI build
# number, which the self-updater prefers for comparisons — successive alphas
# share a core version, so version strings alone cannot order them.
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
manifest="$work_dir/$channel.json"
jq -n \
  --arg version "${tag#v}" \
  --argjson buildNumber "$build_number" \
  --arg releasePageURL "https://github.com/$repository/releases/tag/$tag" \
  --arg origin "$origin/$prefix" \
  '{
    version: $version,
    buildNumber: $buildNumber,
    releasePageURL: $releasePageURL,
    targets: (["linux-arm64","linux-x64","darwin-arm64","darwin-x64"] | map({
      key: .,
      value: {
        archiveURL: ($origin + "/codevisor-server-" + . + ".tar.gz"),
        checksumURL: ($origin + "/codevisor-server-" + . + ".tar.gz.sha256")
      }
    }) | from_entries)
  }' > "$manifest"
aws s3 cp "$manifest" "s3://$bucket/server/$channel.json" \
  --endpoint-url "$R2_S3_API_ENDPOINT" \
  --content-type application/json \
  --cache-control "public, max-age=60"

# The native development bootstrap consumes one immutable GhosttyKit artifact
# keyed by the build stamp. Publishing it on both channels is idempotent.
shopt -s nullglob
ghostty_archives=("$artifact_dir"/GhosttyKit-*.tar.gz)
if [[ "${#ghostty_archives[@]}" -ne 1 ]]; then
  echo "Expected exactly one GhosttyKit development artifact; found ${#ghostty_archives[@]}" >&2
  exit 1
fi
ghostty_archive="${ghostty_archives[0]}"
ghostty_checksum="$ghostty_archive.sha256"
[[ -f "$ghostty_checksum" ]] || { echo "Missing $ghostty_checksum" >&2; exit 1; }
ghostty_name="$(basename "$ghostty_archive")"
ghostty_stamp="${ghostty_name#GhosttyKit-}"
ghostty_stamp="${ghostty_stamp%.tar.gz}"
expected_checksum="$(awk '{print $1}' "$ghostty_checksum")"
actual_checksum="$(sha256sum "$ghostty_archive" | awk '{print $1}')"
if [[ ! "$expected_checksum" =~ ^[0-9a-fA-F]{64}$ || "$actual_checksum" != "$expected_checksum" ]]; then
  echo "GhosttyKit checksum validation failed" >&2
  exit 1
fi
for file in "$ghostty_archive" "$ghostty_checksum"; do
  published_name="GhosttyKit.xcframework.tar.gz"
  content_type=application/gzip
  if [[ "$file" == *.sha256 ]]; then
    published_name="$published_name.sha256"
    content_type=text/plain
  fi
  aws s3 cp "$file" "s3://$bucket/dev-artifacts/ghostty/$ghostty_stamp/$published_name" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type "$content_type" \
    --cache-control "public, max-age=31536000, immutable"
done
