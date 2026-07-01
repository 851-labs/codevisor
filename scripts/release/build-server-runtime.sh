#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-server-runtime.sh <version> <runtime-dir>

Builds a self-contained Node runtime directory for herdman-server and
herdman-terminal-proxy. The runtime includes compiled JS, production
node_modules, and launcher scripts under bin/.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

version="${1:-}"
runtime_dir="${2:-}"

if [[ -z "$version" || -z "$runtime_dir" ]]; then
  usage
  exit 1
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"

if [[ ! -f "$repo_root/apps/server/dist/main.js" ]]; then
  (cd "$repo_root" && bun run build)
fi

rm -rf "$runtime_dir"
mkdir -p \
  "$runtime_dir/apps/server" \
  "$runtime_dir/bin" \
  "$runtime_dir/packages/acp-runtime" \
  "$runtime_dir/packages/api" \
  "$runtime_dir/packages/db" \
  "$runtime_dir/packages/terminal"

cp "$repo_root/package.json" "$runtime_dir/package.json"
cp "$repo_root/bun.lock" "$runtime_dir/bun.lock"
cp "$repo_root/apps/server/package.json" "$runtime_dir/apps/server/package.json"
cp -R "$repo_root/apps/server/dist" "$runtime_dir/apps/server/dist"

for package_name in acp-runtime api db terminal; do
  cp "$repo_root/packages/$package_name/package.json" "$runtime_dir/packages/$package_name/package.json"
  cp -R "$repo_root/packages/$package_name/dist" "$runtime_dir/packages/$package_name/dist"
done

(cd "$runtime_dir" && bun install --production --frozen-lockfile)

find "$runtime_dir/apps/server/dist" "$runtime_dir/packages" \
  \( -name "*.test.js" -o -name "*.test.d.ts" \) \
  -delete

mkdir -p "$runtime_dir/node_modules/@herdman"
for package_name in acp-runtime api db terminal; do
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
exec "${HERDMAN_NODE:-node}" "$root/main.js" "$@"
EOF

cat > "$runtime_dir/bin/herdman-terminal-proxy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "${HERDMAN_NODE:-node}" "$root/terminal-proxy.js" "$@"
EOF

chmod +x "$runtime_dir/bin/herdman-server" "$runtime_dir/bin/herdman-terminal-proxy"
printf "%s\n" "$version" > "$runtime_dir/VERSION"
