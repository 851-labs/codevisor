#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/package-server-js.sh <archive.tar.gz>
       scripts/release/package-server-js.sh --extract <archive.tar.gz>

Packs or restores the compiled server JavaScript (apps/server/dist and every
packages/*/dist) so a slow runner can package a native runtime without
repeating the TypeScript build. The output is platform independent.

Packing requires a completed build-server-runtime.sh run in this checkout.
The archive records the checkout's commit; --extract refuses an archive from a
different commit and replaces any existing dist directories.
EOF
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
revision="$(git -C "$repo_root" rev-parse HEAD)"

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  --extract)
    archive="${2:-}"
    [[ -f "$archive" ]] || { echo "error: server JavaScript archive not found: $archive" >&2; exit 1; }
    staging="$(mktemp -d "${TMPDIR:-/tmp}/codevisor-server-js.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    tar -C "$staging" -xzf "$archive"
    archived_revision="$(<"$staging/SOURCE_REVISION")"
    if [[ "$archived_revision" != "$revision" ]]; then
      echo "error: server JavaScript was built from $archived_revision, not this checkout ($revision)" >&2
      exit 1
    fi
    [[ -f "$staging/apps/server/dist/main.js" ]] || { echo "error: archive has no apps/server/dist/main.js" >&2; exit 1; }
    rm -rf "$repo_root/apps/server/dist" "$repo_root"/packages/*/dist
    cp -R "$staging/apps/server/dist" "$repo_root/apps/server/dist"
    for dist in "$staging"/packages/*/dist; do
      [[ -d "$dist" ]] || continue
      package_name="$(basename "$(dirname "$dist")")"
      [[ -d "$repo_root/packages/$package_name" ]] || { echo "error: archive has unknown package $package_name" >&2; exit 1; }
      cp -R "$dist" "$repo_root/packages/$package_name/dist"
    done
    echo "Restored server JavaScript built from $revision"
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    archive="$1"
    [[ -f "$repo_root/apps/server/dist/main.js" ]] || { echo "error: build the server runtime before packing its JavaScript" >&2; exit 1; }
    staging="$(mktemp -d "${TMPDIR:-/tmp}/codevisor-server-js.XXXXXX")"
    trap 'rm -rf "$staging"' EXIT
    printf '%s\n' "$revision" > "$staging/SOURCE_REVISION"
    mkdir -p "$(dirname "$archive")"
    (
      cd "$repo_root"
      dists=(apps/server/dist)
      for dist in packages/*/dist; do
        [[ -d "$dist" ]] && dists+=("$dist")
      done
      tar -czf "$archive" -C "$staging" SOURCE_REVISION -C "$repo_root" "${dists[@]}"
    )
    echo "$archive"
    ;;
esac
