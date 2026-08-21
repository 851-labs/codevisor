#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="${1:-$repo_root/dist/release}"
framework="$repo_root/apps/macos/Frameworks/GhosttyKit.xcframework"
stamp="$($repo_root/apps/macos/scripts/build-ghostty.sh --print-stamp)"

if [[ ! -d "$framework" ]] || [[ "$(<"$framework/.codevisor-stamp")" != "$stamp" ]]; then
  echo "GhosttyKit.xcframework is missing or does not match $stamp" >&2
  exit 1
fi

mkdir -p "$output_dir"
archive="$output_dir/GhosttyKit-$stamp.tar.gz"
COPYFILE_DISABLE=1 /usr/bin/tar -C "$(dirname "$framework")" -chzf "$archive" "$(basename "$framework")"
checksum="$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$checksum" "$(basename "$archive")" > "$archive.sha256"
echo "$archive"
