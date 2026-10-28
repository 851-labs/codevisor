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

The bundled Node must share .node-version's major version; CI installs that
exact release on every runner, so all targets ship the same Node.

Optional environment:
  CODEVISOR_RELEASE_NODE        Node executable to bundle (default: node on PATH).
  CODEVISOR_PREBUILT_SERVER_JS  Archive from package-server-js.sh for this same
                                source revision. Skips the TypeScript build: the
                                compiled JavaScript is platform independent, so
                                slow runners reuse it and only build native parts.
  CODEVISOR_NODE_GYP            node-gyp executable for native addons (default:
                                the repository's node_modules/.bin/node-gyp).
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

rm -rf "$repo_root/apps/server/dist" "$repo_root/apps/server/tsconfig.tsbuildinfo"
if [[ -n "${CODEVISOR_PREBUILT_SERVER_JS:-}" ]]; then
  "$script_dir/package-server-js.sh" --extract "$CODEVISOR_PREBUILT_SERVER_JS"
else
  (cd "$repo_root" && bun run --cwd apps/server build)
  for plugin_dir in "$repo_root"/plugins/*/; do
    [[ -f "$plugin_dir/package.json" ]] || continue
    (cd "$repo_root" && bun run --cwd "$plugin_dir" build)
  done
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
node_major="v$(cut -d. -f1 < "$repo_root/.node-version")."
if [[ "$node_version" != "$node_major"* ]]; then
  echo "error: Codevisor release artifacts must bundle Node ${node_major}x (.node-version); found $node_version at $node_runtime" >&2
  exit 1
fi

rm -rf "$runtime_dir"
mkdir -p \
  "$runtime_dir/apps/server" \
  "$runtime_dir/bin" \
  "$runtime_dir/packages/agent-runtime" \
  "$runtime_dir/packages/api" \
  "$runtime_dir/packages/cloud-client" \
  "$runtime_dir/packages/cloud-crypto" \
  "$runtime_dir/packages/db" \
  "$runtime_dir/packages/terminal"

cp "$repo_root/package.json" "$runtime_dir/package.json"
cp "$repo_root/bun.lock" "$runtime_dir/bun.lock"
cp -R "$repo_root/patches" "$runtime_dir/patches"
cp "$repo_root/apps/server/package.json" "$runtime_dir/apps/server/package.json"
cp -R "$repo_root/apps/server/dist" "$runtime_dir/apps/server/dist"

for package_dir in "$repo_root"/packages/*/; do
  package_name="$(basename "$package_dir")"
  [[ -d "$package_dir/dist" ]] || continue
  mkdir -p "$runtime_dir/packages/$package_name"
  cp "$package_dir/package.json" "$runtime_dir/packages/$package_name/package.json"
  cp -R "$package_dir/dist" "$runtime_dir/packages/$package_name/dist"
  if [[ -d "$package_dir/resources" ]]; then
    cp -R "$package_dir/resources" "$runtime_dir/packages/$package_name/resources"
  fi
done

for catalog_file in "$repo_root"/plugins/*.json; do
  [[ -f "$catalog_file" ]] || continue
  mkdir -p "$runtime_dir/plugins"
  cp "$catalog_file" "$runtime_dir/plugins/"
done
is_dev_only_plugin() {
  [[ -f "$1" ]] && node -e '
    const meta = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))._meta
    process.exit(meta?.["dev.codevisor/plugin"]?.devOnly === true ? 0 : 1)
  ' "$1"
}

for plugin_dir in "$repo_root"/plugins/*/; do
  plugin_name="$(basename "$plugin_dir")"
  [[ -f "$plugin_dir/package.json" ]] || continue
  is_dev_only_plugin "$plugin_dir/server.json" && continue
  if [[ ! -d "$plugin_dir/dist" ]]; then
    echo "error: plugin $plugin_name has no dist; build it before packaging the runtime" >&2
    exit 1
  fi
  mkdir -p "$runtime_dir/plugins/$plugin_name"
  cp "$plugin_dir/package.json" "$runtime_dir/plugins/$plugin_name/package.json"
  cp -R "$plugin_dir/dist" "$runtime_dir/plugins/$plugin_name/dist"
  if [[ -f "$plugin_dir/server.json" ]]; then
    cp "$plugin_dir/server.json" "$runtime_dir/plugins/$plugin_name/server.json"
  fi
done

node "$repo_root/scripts/net-artifact.mjs" ensure-node >/dev/null
mkdir -p "$runtime_dir/packages/net/native/$target"
cp "$repo_root/packages/net/native/$target/codevisor_net.node" "$runtime_dir/packages/net/native/$target/"

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

for manifest in "$repo_root"/apps/*/package.json "$repo_root"/packages/*/package.json "$repo_root"/plugins/*/package.json; do
  [[ -f "$manifest" ]] || continue
  relative="${manifest#"$repo_root"/}"
  if [[ ! -f "$runtime_dir/$relative" ]]; then
    mkdir -p "$runtime_dir/$(dirname "$relative")"
    cp "$manifest" "$runtime_dir/$relative"
  fi
done

node_gyp="${CODEVISOR_NODE_GYP:-$repo_root/node_modules/.bin/node-gyp}"
if [[ ! -x "$node_gyp" ]]; then
  echo "error: node-gyp is required to build the packaged server runtime. Run bun install first or set CODEVISOR_NODE_GYP." >&2
  exit 1
fi

(cd "$runtime_dir" && PATH="$node_runtime_dir:$PATH" npm_config_node_gyp="$node_gyp" bun install --production --frozen-lockfile --filter '@codevisor/server' --filter './plugins/*' --linker hoisted)
cp "$node_runtime" "$runtime_dir/bin/node"
chmod +x "$runtime_dir/bin/node"
echo "Bundled $node_version from $node_runtime"

find "$runtime_dir/apps/server/dist" "$runtime_dir/packages" "$runtime_dir/plugins" \
  \( -name "*.test.js" -o -name "*.test.d.ts" \) \
  -delete

rm -rf "$runtime_dir"/node_modules/@anthropic-ai/claude-agent-sdk-*
rm -rf "$runtime_dir"/node_modules/.bun/@anthropic-ai+claude-agent-sdk-* 2>/dev/null || true
leftover=$(find "$runtime_dir/node_modules" -maxdepth 3 -type d -name "claude-agent-sdk-*" | head -1)
if [[ -n "$leftover" ]]; then
  echo "error: Claude Agent SDK platform runtime survived the prune: $leftover" >&2
  exit 1
fi

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
for package_name in agent-runtime api cloud-client cloud-crypto db terminal; do
  rm -f "$runtime_dir/node_modules/@codevisor/$package_name"
  ln -s "../../packages/$package_name" "$runtime_dir/node_modules/@codevisor/$package_name"
done

cp "$runtime_dir/apps/server/dist/"*.js "$runtime_dir/"
cp "$runtime_dir/apps/server/dist/"*.d.ts "$runtime_dir/" 2>/dev/null || true
for subdir in "$runtime_dir/apps/server/dist"/*/; do
  subdir_name="$(basename "$subdir")"
  mkdir -p "$runtime_dir/$subdir_name"
  cp -R "$subdir". "$runtime_dir/$subdir_name/"
done

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
build_number="${CODEVISOR_BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
source_revision="${CODEVISOR_SOURCE_REVISION:-${GITHUB_SHA:-unknown}}"
printf '{"version":"%s","buildNumber":%s,"sourceRevision":"%s","target":"%s"}\n' \
  "$version" "$build_number" "$source_revision" "$target" > "$runtime_dir/BUILD.json"

runtime_root="$(cd "$runtime_dir" && pwd -P)"
(
  cd /
  CODEVISOR_SMOKE_RUNTIME="$runtime_root" "$runtime_root/bin/node" --input-type=module -e '
    const { pathToFileURL } = await import("node:url")
    const runtime = process.env.CODEVISOR_SMOKE_RUNTIME
    const relay = await import(
      pathToFileURL(`${runtime}/packages/automation/dist/browser-extension-relay.js`)
    )
    if (relay.browserExtensionPath() === undefined) {
      throw new Error("Packaged browser extension is not discoverable from /")
    }
    const mcp = await import(pathToFileURL(`${runtime}/packages/mcp/dist/mcp-manager.js`))
    for (const id of ["browser", "computer"]) {
      if (!mcp.automationSkillPath(id).startsWith(runtime)) {
        throw new Error(`Packaged ${id} skill is not discoverable from /`)
      }
    }
    const computer = await import(
      pathToFileURL(`${runtime}/packages/automation/dist/computer-use-provider.js`)
    )
    if (!computer.linuxComputerUseHelperPath()?.startsWith(runtime)) {
      throw new Error("Packaged Linux Computer Use helper is not discoverable from /")
    }
  '
)
