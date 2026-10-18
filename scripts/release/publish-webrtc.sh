#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: publish-webrtc.sh <version> <artifact-dir>" >&2
}

version="${1:-}"
artifact_dir="${2:-}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-codevisor\.[0-9]+$ || -z "$artifact_dir" ]]; then
  usage
  exit 1
fi
for variable in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY R2_S3_API_ENDPOINT; do
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
prefix="dev-artifacts/webrtc/$version"
archive="$artifact_dir/WebRTC.xcframework.zip"
manifest="$artifact_dir/manifest.json"

[[ -f "$archive" && -f "$manifest" ]] || { echo "Missing the archive or manifest in $artifact_dir" >&2; exit 1; }
expected_checksum="$(jq -r .sha256 "$manifest")"
actual_checksum="$(sha256sum "$archive" | awk '{print $1}')"
if [[ ! "$expected_checksum" =~ ^[0-9a-f]{64}$ || "$actual_checksum" != "$expected_checksum" ]]; then
  echo "WebRTC archive checksum does not match its manifest" >&2
  exit 1
fi

if error="$(aws s3api head-object --bucket "$bucket" --key "$prefix/WebRTC.xcframework.zip" \
  --endpoint-url "$R2_S3_API_ENDPOINT" 2>&1 >/dev/null)"; then
  echo "WebRTC $version is already published; choose a new version" >&2
  exit 1
elif [[ "$error" != *"Not Found"* && "$error" != *"404"* ]]; then
  echo "Could not check for an existing WebRTC $version: $error" >&2
  exit 1
fi

upload() {
  aws s3 cp "$1" "s3://$bucket/$prefix/$2" \
    --endpoint-url "$R2_S3_API_ENDPOINT" \
    --content-type "$3" \
    --cache-control "public, max-age=31536000, immutable"
}

upload "$manifest" manifest.json application/json
upload "$artifact_dir/revisions.txt" revisions.txt text/plain
for file in "$artifact_dir"/*-gn-args.txt; do
  upload "$file" "$(basename "$file")" text/plain
done
upload "$artifact_dir/notices-macos/LICENSE.md" ThirdPartyNotices-macOS.md text/markdown
upload "$artifact_dir/notices-ios/LICENSE.md" ThirdPartyNotices-iOS.md text/markdown
upload "$archive" WebRTC.xcframework.zip application/zip

cat <<SNIPPET
Published WebRTC $version. Pin it in packages/swift/Package.swift:
    .binaryTarget(
      name: "WebRTC",
      url: "$origin/$prefix/WebRTC.xcframework.zip",
      checksum: "$actual_checksum"
    ),
SNIPPET
