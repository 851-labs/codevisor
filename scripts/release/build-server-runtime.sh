#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

usage() {
  cat >&2 <<'EOF'
usage: scripts/release/build-server-runtime.sh <version> <runtime-dir> [target]

Builds a self-contained Node runtime directory for codevisor-server and
codevisor-terminal-proxy. The runtime includes compiled JS, production
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

node_runtime="${CODEVISOR_RELEASE_NODE:-$(command -v node || true)}"
if [[ -z "$node_runtime" || ! -x "$node_runtime" ]]; then
  echo "error: a Node executable is required to package the Codevisor server runtime." >&2
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
    echo "error: Codevisor release artifacts must bundle Node 24.x; found $node_version at $node_runtime" >&2
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
cp -R "$repo_root/apps/server/resources" "$runtime_dir/apps/server/resources"

for package_name in agent-runtime api db terminal; do
  cp "$repo_root/packages/$package_name/package.json" "$runtime_dir/packages/$package_name/package.json"
  cp -R "$repo_root/packages/$package_name/dist" "$runtime_dir/packages/$package_name/dist"
done

# Keep Ghostty's terminfo database next to @codevisor/terminal in both macOS
# and Linux lookup layouts. Linux PTYs advertise the portable xterm-256color
# baseline, but the Ghostty entry remains available to macOS and explicit
# shell configuration without modifying the host terminfo database.
terminal_resources="$repo_root/packages/terminal/resources"
for entry in \
  terminfo/78/xterm-ghostty \
  terminfo/67/ghostty \
  terminfo/x/xterm-ghostty \
  terminfo/g/ghostty; do
  if [[ ! -f "$terminal_resources/$entry" ]]; then
    echo "error: bundled terminfo entry is missing: $terminal_resources/$entry" >&2
    exit 1
  fi
done
if ! cmp -s \
  "$terminal_resources/terminfo/78/xterm-ghostty" \
  "$terminal_resources/terminfo/x/xterm-ghostty" \
  || ! cmp -s \
    "$terminal_resources/terminfo/67/ghostty" \
    "$terminal_resources/terminfo/g/ghostty"; then
  echo "error: macOS and Linux terminfo entries are out of sync" >&2
  exit 1
fi
cp -R "$terminal_resources" "$runtime_dir/packages/terminal/resources"

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
(cd "$runtime_dir" && PATH="$node_runtime_dir:$PATH" npm_config_node_gyp="$node_gyp" bun install --production --frozen-lockfile --filter '@codevisor/server' --linker hoisted)
cp "$node_runtime" "$runtime_dir/bin/node"
chmod +x "$runtime_dir/bin/node"
echo "Bundled $node_version from $node_runtime"

find "$runtime_dir/apps/server/dist" "$runtime_dir/packages" \
  \( -name "*.test.js" -o -name "*.test.d.ts" \) \
  -delete

# The Claude provider drives the user's own `claude` binary via
# pathToClaudeCodeExecutable; the Agent SDK's vendored CLI runtime (~200MB per
# platform, shipped as optionalDependencies) is never executed and must not
# ship in the runtime.
rm -rf "$runtime_dir"/node_modules/@anthropic-ai/claude-agent-sdk-*
rm -rf "$runtime_dir"/node_modules/.bun/@anthropic-ai+claude-agent-sdk-* 2>/dev/null || true
leftover=$(find "$runtime_dir/node_modules" -maxdepth 3 -type d -name "claude-agent-sdk-*" | head -1)
if [[ -n "$leftover" ]]; then
  echo "error: Claude Agent SDK platform runtime survived the prune: $leftover" >&2
  exit 1
fi

# Strip non-runtime files from the bundled dependencies (~65MB, a quarter of
# the runtime): TypeScript sources and declarations, sourcemaps, and docs are
# never read by Node; better-sqlite3's deps/ and src/ plus node-gyp's
# obj.target intermediates only matter at compile time; and the QuickJS debug
# wasm payloads back a DEBUG variant the server never instantiates (their
# packages stay resolvable — quickjs-emscripten requires all variant packages
# at load time, but each loads its wasm payload with a lazy dynamic import).
# package.json and LICENSE files stay.
find "$runtime_dir/node_modules" -type f \
  \( -name "*.ts" -o -name "*.mts" -o -name "*.cts" \
  -o -name "*.map" -o -name "*.md" -o -name "*.markdown" \) \
  ! -iname "license*" ! -iname "copying*" \
  -delete
rm -rf "$runtime_dir/node_modules/better-sqlite3/deps" \
  "$runtime_dir/node_modules/better-sqlite3/src"
find "$runtime_dir/node_modules" -type d -name "obj.target" -prune -exec rm -rf {} +
rm -f "$runtime_dir"/node_modules/@jitl/quickjs-wasmfile-debug-*/dist/emscripten-module*

mkdir -p "$runtime_dir/node_modules/@codevisor"
for package_name in agent-runtime api db terminal; do
  rm -f "$runtime_dir/node_modules/@codevisor/$package_name"
  ln -s "../../packages/$package_name" "$runtime_dir/node_modules/@codevisor/$package_name"
done

# The macOS app looks for Resources/server/main.js and terminal-proxy.js.
# Keep copies at the runtime root while preserving apps/server/dist for package
# manager metadata and symlink targets.
cp "$runtime_dir/apps/server/dist/"*.js "$runtime_dir/"
cp "$runtime_dir/apps/server/dist/"*.d.ts "$runtime_dir/" 2>/dev/null || true
# cli.js resolves its command implementations from ./cli/ relative to itself.
rm -rf "$runtime_dir/cli"
cp -R "$runtime_dir/apps/server/dist/cli" "$runtime_dir/cli"

# Launchers resolve symlinks before locating the runtime root: install.sh
# links them into ~/.local/bin or /usr/local/bin, and an unresolved
# BASH_SOURCE would look for the bundled node next to the symlink instead of
# the runtime (breaking every invocation via PATH).
write_launcher() {
  local name="$1" entry="$2"
  cat > "$runtime_dir/bin/$name" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source="\${BASH_SOURCE[0]}"
while [ -L "\$source" ]; do
  dir="\$(cd -P "\$(dirname "\$source")" && pwd)"
  source="\$(readlink "\$source")"
  [[ \$source != /* ]] && source="\$dir/\$source"
done
root="\$(cd -P "\$(dirname "\$source")/.." && pwd)"
node_bin="\${CODEVISOR_NODE:-}"
if [[ -z "\$node_bin" && -x "\$root/bin/node" ]]; then
  node_bin="\$root/bin/node"
fi
exec -a $name "\${node_bin:-node}" "\$root/$entry" "\$@"
EOF
}

write_launcher codevisor-server main.js
write_launcher codevisor-terminal-proxy terminal-proxy.js
write_launcher codevisor cli.js

chmod +x "$runtime_dir/bin/codevisor-server" "$runtime_dir/bin/codevisor-terminal-proxy" \
  "$runtime_dir/bin/codevisor"
printf "%s\n" "$version" > "$runtime_dir/VERSION"
printf "%s\n" "$target" > "$runtime_dir/TARGET"

# LaunchServices starts the macOS app with / as its working directory. Probe
# resource discovery from there so a runtime layout regression cannot ship a
# server that stays alive without ever opening its health port.
runtime_root="$(cd "$runtime_dir" && pwd)"
(
  cd /
  CODEVISOR_SMOKE_RUNTIME="$runtime_root" "$runtime_root/bin/node" --input-type=module -e '
    const { pathToFileURL } = await import("node:url")
    const runtime = process.env.CODEVISOR_SMOKE_RUNTIME
    const relay = await import(pathToFileURL(`${runtime}/browser-extension-relay.js`))
    if (relay.browserExtensionPath() === undefined) {
      throw new Error("Packaged browser extension is not discoverable from /")
    }
  '
)
