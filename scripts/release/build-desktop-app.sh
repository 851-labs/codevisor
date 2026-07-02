#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-desktop-app.sh <version> <output-dir>

Builds the Tauri desktop app (apps/desktop): builds the web SPA and the local
server runtime, stages the runtime into src-tauri/resources/server/<target>,
pre-signs the bundled node binary, then runs `tauri build` for the host
architecture. Produces HerdMan.app + a .dmg under the Tauri bundle directory
and copies them into <output-dir>.

Optional environment:
  APPLE_CODESIGN_IDENTITY       Developer ID Application identity; empty for ad-hoc signing.
                                (Exported as APPLE_SIGNING_IDENTITY for the Tauri bundler.)
  HERDMAN_DARWIN_ARM64_RUNTIME_ARCHIVE
                                Optional prebuilt darwin-arm64 server runtime tarball.
  HERDMAN_DARWIN_X64_RUNTIME_ARCHIVE
                                Optional prebuilt darwin-x64 server runtime tarball.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
output_dir="${2:-}"

if [[ -z "$version" || -z "$output_dir" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
node_entitlements="$script_dir/node-entitlements.plist"
resources_dir="$repo_root/apps/desktop/src-tauri/resources/server"

case "$(uname -m)" in
  arm64) target="darwin-arm64"; rust_target="aarch64-apple-darwin" ;;
  x86_64) target="darwin-x64"; rust_target="x86_64-apple-darwin" ;;
  *) echo "error: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "$output_dir"

# 1. Build the workspace (server dist + web dist via turbo).
(cd "$repo_root" && bun install && bun run build)

# 2. Stage the server runtime (main.js + bin/node + VERSION) for this target.
rm -rf "$resources_dir/$target"
runtime_archive_var="HERDMAN_$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_RUNTIME_ARCHIVE"
runtime_archive="${!runtime_archive_var:-}"
if [[ -n "$runtime_archive" && -f "$runtime_archive" ]]; then
  mkdir -p "$resources_dir/$target"
  tar -xzf "$runtime_archive" -C "$resources_dir/$target"
else
  "$script_dir/build-server-runtime.sh" "$version" "$resources_dir/$target" "$target"
fi

# 3. Pre-sign the bundled node with the hardened runtime + JIT entitlements —
#    the Tauri bundler does not deep-sign resource executables.
identity="${APPLE_CODESIGN_IDENTITY:-}"
node_binary="$resources_dir/$target/bin/node"
if [[ -x "$node_binary" ]]; then
  if [[ -n "$identity" ]]; then
    codesign --force --options runtime --timestamp \
      --entitlements "$node_entitlements" --sign "$identity" "$node_binary"
  else
    codesign --force --entitlements "$node_entitlements" --sign - "$node_binary"
  fi
fi

# 4. Build the Tauri bundle. The bundler picks up APPLE_SIGNING_IDENTITY (and
#    the notarytool APPLE_* variables when set) for signing + notarization.
if [[ -n "$identity" ]]; then
  export APPLE_SIGNING_IDENTITY="$identity"
fi
(cd "$repo_root/apps/desktop" && bunx tauri build --target "$rust_target")

bundle_dir="$repo_root/apps/desktop/src-tauri/target/$rust_target/release/bundle"
cp -R "$bundle_dir/macos/HerdMan.app" "$output_dir/"
find "$bundle_dir/dmg" -name '*.dmg' -exec cp {} "$output_dir/HerdMan-desktop-$target.dmg" \; 2>/dev/null || true

echo "Desktop app staged in $output_dir"
