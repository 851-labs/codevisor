#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-server-archive.sh <version> <output-dir> [target]

Builds herdman-server-<target>.tar.gz for the current machine unless target is
provided. The archive is intended for the Homebrew formula.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
output_dir="${2:-}"
target="${3:-}"

if [[ -z "$version" || -z "$output_dir" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
if [[ -z "$target" ]]; then
  target="$("$script_dir/detect-target.sh")"
fi

work_dir="$repo_root/dist/release/work/server-$target"
runtime_dir="$work_dir/runtime"
archive_name="herdman-server-$target.tar.gz"
archive_path="$output_dir/$archive_name"

mkdir -p "$output_dir"
"$script_dir/build-server-runtime.sh" "$version" "$runtime_dir"

rm -f "$archive_path"
tar -C "$runtime_dir" -czf "$archive_path" .
shasum -a 256 "$archive_path" | awk '{print $1}' > "$archive_path.sha256"
echo "$archive_path"
