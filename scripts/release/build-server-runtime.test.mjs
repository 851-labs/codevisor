import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { access, copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import test from "node:test"

const patch = "patches/nested directory/dependency@1.0.0.patch"

const fakeBun = `#!/bin/sh
set -eu
case "$1" in
  run)
    mkdir -p apps/server/dist
    printf 'fixture' > apps/server/dist/main.js
    ;;
  install)
    printf '%s' "$PWD" > "$PACKAGED_INSTALL_DIRECTORY"
    printf '%s\\n' "$@" > "$PACKAGED_INSTALL_ARGS"
    exit 73
    ;;
  *) exit 74 ;;
esac
`

const baseFiles = {
  "package.json": JSON.stringify({ patchedDependencies: { "dependency@1.0.0": patch } }),
  "bun.lock": "fixture",
  ".node-version": process.versions.node,
  "apps/server/package.json": JSON.stringify({ name: "@codevisor/server" }),
  "scripts/net-artifact.mjs": "",
  "packages/net/native/fixture-target/codevisor_net.node": "fixture",
  [patch]: "dependency patch contents\n",
  "bin/node-gyp": "#!/bin/sh\nexit 0\n",
  "scripts/release/detect-target.sh": "#!/bin/sh\nprintf 'fixture-target\\n'\n",
  "bin/bun": fakeBun
}

const packageRuntime = async (t, extraFiles = {}) => {
  const root = await mkdtemp(join(tmpdir(), "codevisor runtime patches "))
  t.after(() => rm(root, { recursive: true, force: true }))
  const script = join(root, "scripts/release/build-server-runtime.sh")
  await mkdir(dirname(script), { recursive: true })
  await copyFile(new URL("./build-server-runtime.sh", import.meta.url), script)
  for (const [path, content] of Object.entries({ ...baseFiles, ...extraFiles })) {
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
  const capturedArgs = join(root, "install-args")
  const result = spawnSync("bash", [script, "0.0.0", runtime], {
    cwd: root,
    encoding: "utf8",
    env: {
      PATH: `${join(root, "bin")}:${process.env.PATH}`,
      CODEVISOR_RELEASE_NODE: process.execPath,
      CODEVISOR_NODE_GYP: join(root, "bin/node-gyp"),
      PACKAGED_INSTALL_DIRECTORY: captured,
      PACKAGED_INSTALL_ARGS: capturedArgs
    }
  })
  return { result, runtime, captured, capturedArgs }
}

test("the production install can resolve dependency patches in the staged runtime", async (t) => {
  const { result, runtime, captured } = await packageRuntime(t)

  assert.equal(result.status, 73, result.stderr)
  const installDirectory = await readFile(captured, "utf8")
  assert.equal(installDirectory, runtime)
  assert.equal(await readFile(join(installDirectory, patch), "utf8"), "dependency patch contents\n")
})

test("first-party plugins ship their package.json, server.json and dist, and are installed", async (t) => {
  const { result, runtime, capturedArgs } = await packageRuntime(t, {
    "plugins/popular.json": JSON.stringify({ servers: [] }),
    "plugins/kit/package.json": JSON.stringify({ name: "@codevisor/plugin-kit" }),
    "plugins/kit/dist/index.js": "export {}\n",
    "plugins/gmail/package.json": JSON.stringify({ name: "@codevisor/plugin-gmail" }),
    "plugins/gmail/server.json": JSON.stringify({ name: "dev.codevisor/gmail" }),
    "plugins/gmail/dist/main.js": "export {}\n",
    "plugins/gmail/src/main.ts": "export {}\n"
  })

  assert.equal(result.status, 73, result.stderr)
  assert.equal(
    await readFile(join(runtime, "plugins/gmail/server.json"), "utf8"),
    '{"name":"dev.codevisor/gmail"}'
  )
  assert.equal(await readFile(join(runtime, "plugins/gmail/dist/main.js"), "utf8"), "export {}\n")
  assert.equal(await readFile(join(runtime, "plugins/popular.json"), "utf8"), '{"servers":[]}')
  await access(join(runtime, "plugins/gmail/package.json"))
  await access(join(runtime, "plugins/kit/dist/index.js"))
  await assert.rejects(access(join(runtime, "plugins/gmail/src")))
  await assert.rejects(access(join(runtime, "plugins/kit/server.json")))
  const args = (await readFile(capturedArgs, "utf8")).trim().split("\n")
  assert.deepEqual(args.slice(args.indexOf("--filter")), [
    "--filter",
    "@codevisor/server",
    "--filter",
    "./plugins/*",
    "--linker",
    "hoisted"
  ])
})

test("dev-only plugins stay out of the packaged runtime", async (t) => {
  const devOnly = {
    name: "dev.codevisor/test-events",
    _meta: { "dev.codevisor/plugin": { devOnly: true } }
  }
  const { result, runtime } = await packageRuntime(t, {
    "plugins/popular.json": JSON.stringify({ servers: [] }),
    "plugins/test-events/package.json": JSON.stringify({ name: "@codevisor/plugin-test-events" }),
    "plugins/test-events/server.json": JSON.stringify(devOnly),
    "plugins/test-events/dist/main.js": "export {}\n"
  })

  assert.equal(result.status, 73, result.stderr)
  await assert.rejects(access(join(runtime, "plugins/test-events/server.json")))
  await assert.rejects(access(join(runtime, "plugins/test-events/dist")))
})

test("packaging fails when a plugin was not built", async (t) => {
  const { result } = await packageRuntime(t, {
    "plugins/gmail/package.json": JSON.stringify({ name: "@codevisor/plugin-gmail" })
  })

  assert.equal(result.status, 1)
  assert.match(result.stderr, /plugin gmail has no dist/)
})
