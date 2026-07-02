#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-server-runtime.sh <version> <runtime-dir> [target]

Builds a self-contained Node runtime directory for herdman-server and
herdman-terminal-proxy. The runtime includes compiled JS, production
node_modules, a pinned Node executable, and launcher scripts under bin/.

The optional target must match the current machine. Native Node addons are
compiled during packaging, so cross-building the runtime would produce an app
that fails on the target CPU.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
runtime_dir="${2:-}"
target="${3:-}"

if [[ -z "$version" || -z "$runtime_dir" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
host_target="$("$script_dir/detect-target.sh")"
if [[ -z "$target" ]]; then
  target="$host_target"
fi
if [[ "$target" != "$host_target" ]]; then
  echo "error: cannot build $target runtime on $host_target. Use a native $target runner." >&2
  exit 1
fi

if [[ ! -f "$repo_root/apps/server/dist/main.js" ]]; then
  (cd "$repo_root" && bun run build)
fi

node_runtime="${HERDMAN_RELEASE_NODE:-$(command -v node || true)}"
if [[ -z "$node_runtime" || ! -x "$node_runtime" ]]; then
  echo "error: a Node executable is required to package the HerdMan server runtime." >&2
  exit 1
fi
node_runtime_dir="$(cd "$(dirname "$node_runtime")" && pwd)"

if ! node_version="$("$node_runtime" --version 2>/dev/null)"; then
  echo "error: failed to read Node version from $node_runtime" >&2
  exit 1
fi
case "$node_version" in
  v24.*) ;;
  *)
    echo "error: HerdMan release artifacts must bundle Node 24.x; found $node_version at $node_runtime" >&2
    exit 1
    ;;
esac

rm -rf "$runtime_dir"
mkdir -p \
  "$runtime_dir/apps/server" \
  "$runtime_dir/bin" \
  "$runtime_dir/packages/agent-runtime" \
  "$runtime_dir/packages/api" \
  "$runtime_dir/packages/db" \
  "$runtime_dir/packages/terminal"

cp "$repo_root/package.json" "$runtime_dir/package.json"
cp "$repo_root/bun.lock" "$runtime_dir/bun.lock"
cp "$repo_root/apps/server/package.json" "$runtime_dir/apps/server/package.json"
cp -R "$repo_root/apps/server/dist" "$runtime_dir/apps/server/dist"

for package_name in agent-runtime api db terminal; do
  cp "$repo_root/packages/$package_name/package.json" "$runtime_dir/packages/$package_name/package.json"
  cp -R "$repo_root/packages/$package_name/dist" "$runtime_dir/packages/$package_name/dist"
done

# The lockfile spans every workspace member, so bun's frozen install needs
# each manifest present even though the runtime only ships the server code.
for manifest in "$repo_root"/apps/*/package.json "$repo_root"/packages/*/package.json; do
  [[ -f "$manifest" ]] || continue
  relative="${manifest#"$repo_root"/}"
  if [[ ! -f "$runtime_dir/$relative" ]]; then
    mkdir -p "$runtime_dir/$(dirname "$relative")"
    cp "$manifest" "$runtime_dir/$relative"
  fi
done

node_gyp="$repo_root/node_modules/.bin/node-gyp"
if [[ ! -x "$node_gyp" ]]; then
  echo "error: node-gyp is required to build the packaged server runtime. Run bun install first." >&2
  exit 1
fi

# Filtered to the server workspace so the other apps' dependency trees stay
# out of the runtime; hoisted keeps the classic node_modules layout that the
# bundled Node resolves (and that survives zipping into the app bundle).
(cd "$runtime_dir" && PATH="$node_runtime_dir:$PATH" npm_config_node_gyp="$node_gyp" bun install --production --frozen-lockfile --filter '@herdman/server' --linker hoisted)
cp "$node_runtime" "$runtime_dir/bin/node"
chmod +x "$runtime_dir/bin/node"
echo "Bundled $node_version from $node_runtime"

find "$runtime_dir/apps/server/dist" "$runtime_dir/packages" \
  \( -name "*.test.js" -o -name "*.test.d.ts" \) \
  -delete

mkdir -p "$runtime_dir/node_modules/@herdman"
for package_name in agent-runtime api db terminal; do
  rm -f "$runtime_dir/node_modules/@herdman/$package_name"
  ln -s "../../packages/$package_name" "$runtime_dir/node_modules/@herdman/$package_name"
done

# The macOS app looks for Resources/server/main.js and terminal-proxy.js.
# Keep copies at the runtime root while preserving apps/server/dist for package
# manager metadata and symlink targets.
cp "$runtime_dir/apps/server/dist/"*.js "$runtime_dir/"
cp "$runtime_dir/apps/server/dist/"*.d.ts "$runtime_dir/" 2>/dev/null || true

cat > "$runtime_dir/bin/herdman-server" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_bin="${HERDMAN_NODE:-}"
if [[ -z "$node_bin" && -x "$root/bin/node" ]]; then
  node_bin="$root/bin/node"
fi
exec "${node_bin:-node}" "$root/main.js" "$@"
EOF

cat > "$runtime_dir/bin/herdman-terminal-proxy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node_bin="${HERDMAN_NODE:-}"
if [[ -z "$node_bin" && -x "$root/bin/node" ]]; then
  node_bin="$root/bin/node"
fi
exec "${node_bin:-node}" "$root/terminal-proxy.js" "$@"
EOF

chmod +x "$runtime_dir/bin/herdman-server" "$runtime_dir/bin/herdman-terminal-proxy"
printf "%s\n" "$version" > "$runtime_dir/VERSION"
printf "%s\n" "$target" > "$runtime_dir/TARGET"
