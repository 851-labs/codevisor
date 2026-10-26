import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import test from "node:test"

test("the production install can resolve dependency patches in the staged runtime", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "codevisor runtime patches "))
  t.after(() => rm(root, { recursive: true, force: true }))
  const script = join(root, "scripts/release/build-server-runtime.sh")
  await mkdir(dirname(script), { recursive: true })
  await copyFile(new URL("./build-server-runtime.sh", import.meta.url), script)
  const patch = "patches/nested directory/dependency@1.0.0.patch"
  const files = {
    "package.json": JSON.stringify({ patchedDependencies: { "dependency@1.0.0": patch } }),
    "bun.lock": "fixture",
    ".node-version": process.versions.node,
    "apps/server/package.json": JSON.stringify({ name: "@codevisor/server" }),
    "scripts/net-artifact.mjs": "",
    "packages/net/native/fixture-target/codevisor_net.node": "fixture",
    [patch]: "dependency patch contents\n",
    "bin/node-gyp": "#!/bin/sh\nexit 0\n",
    "scripts/release/detect-target.sh": "#!/bin/sh\nprintf 'fixture-target\\n'\n",
    "bin/bun": `#!/bin/sh
set -eu
case "$1" in
  run)
    mkdir -p apps/server/dist
    printf 'fixture' > apps/server/dist/main.js
    ;;
  install)
    printf '%s' "$PWD" > "$PACKAGED_INSTALL_DIRECTORY"
    exit 73
    ;;
  *) exit 74 ;;
esac
`
  }
  for (const [path, content] of Object.entries(files)) {
    const destination = join(root, path)
    await mkdir(dirname(destination), { recursive: true })
    await writeFile(destination, content, { mode: 0o755 })
  }
  for (const prefix of ["78/xterm-ghostty", "67/ghostty", "x/xterm-ghostty", "g/ghostty"]) {
    const destination = join(root, "packages/terminal/resources/terminfo", prefix)
    await mkdir(dirname(destination), { recursive: true })
    await writeFile(destination, "terminfo")
  }

  const runtime = join(root, "packaged runtime")
  const captured = join(root, "install-directory")
  const result = spawnSync("bash", [script, "0.0.0", runtime], {
    cwd: root,
    encoding: "utf8",
    env: {
      PATH: `${join(root, "bin")}:${process.env.PATH}`,
      CODEVISOR_RELEASE_NODE: process.execPath,
      CODEVISOR_NODE_GYP: join(root, "bin/node-gyp"),
      PACKAGED_INSTALL_DIRECTORY: captured
    }
  })
  assert.equal(result.status, 73, result.stderr)
  const installDirectory = await readFile(captured, "utf8")
  assert.equal(installDirectory, runtime)
  assert.equal(await readFile(join(installDirectory, patch), "utf8"), "dependency patch contents\n")
})
