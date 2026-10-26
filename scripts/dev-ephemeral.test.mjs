import assert from "node:assert/strict"
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import {
  ensureDevServerArchive,
  parseDefaultRouteInterface,
  resolveDevVmHost,
  serveDevEphemeralArtifacts,
  serverInputsKey
} from "./dev-ephemeral.mjs"

const interfaces = () => ({
  lo0: [{ family: "IPv4", address: "127.0.0.1", internal: true }],
  en0: [
    { family: "IPv6", address: "fe80::1", internal: false },
    { family: "IPv4", address: "192.168.10.200", internal: false }
  ],
  bridge100: [{ family: "IPv4", address: "192.168.64.1", internal: false }]
})

const fakeRepo = async (t) => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-dev-ephemeral-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, "apps/server/dist"), { recursive: true })
  await mkdir(join(root, "apps/www/public"), { recursive: true })
  await mkdir(join(root, "packages/api/dist"), { recursive: true })
  await mkdir(join(root, "scripts/release"), { recursive: true })
  await writeFile(join(root, "apps/server/dist/main.js"), "export {}\n")
  await writeFile(join(root, "packages/api/dist/index.js"), "export {}\n")
  await writeFile(join(root, "apps/www/public/install.sh"), "#!/bin/sh\necho install\n")
  await writeFile(join(root, "bun.lock"), "{}\n")
  await writeFile(join(root, "scripts/release/detect-target.sh"), "#!/bin/sh\necho darwin-arm64\n")
  await chmod(join(root, "scripts/release/detect-target.sh"), 0o755)
  return root
}

test("Tart VMs reach this Mac at its default route's IPv4 address", async () => {
  const host = await resolveDevVmHost({
    tartInstalled: async () => true,
    defaultRoute: async () => "en0",
    interfaces
  })

  assert.equal(host, "192.168.10.200")
})

test("without Tart or a default route there is no VM-facing address", async () => {
  const withoutTart = await resolveDevVmHost({
    tartInstalled: async () => false,
    defaultRoute: async () => "en0",
    interfaces
  })
  const offline = await resolveDevVmHost({
    tartInstalled: async () => true,
    defaultRoute: async () => undefined,
    interfaces
  })

  assert.equal(withoutTart, undefined)
  assert.equal(offline, undefined)
})

test("the default route's interface is read from route's output", () => {
  const output = "   route to: default\ndestination: default\n  interface: en0\n      flags: <UP>\n"

  assert.equal(parseDefaultRouteInterface(output), "en0")
  assert.equal(
    parseDefaultRouteInterface("route: writing to routing socket: not in table\n"),
    undefined
  )
})

test("the artifacts server hands out the working tree's installer and the built archives only", async (t) => {
  const repoRoot = await fakeRepo(t)
  const archiveRoot = join(repoRoot, "archives")
  await mkdir(archiveRoot)
  await writeFile(join(archiveRoot, "codevisor-server-darwin-arm64.tar.gz"), "archive")
  await writeFile(join(archiveRoot, "codevisor-server-darwin-arm64.tar.gz.sha256"), "digest")
  await writeFile(join(archiveRoot, "inputs.sha256"), "key")
  const { server, url } = await serveDevEphemeralArtifacts({
    repoRoot,
    archiveRoot,
    host: "127.0.0.1"
  })
  t.after(() => new Promise((resolve) => server.close(resolve)))

  const body = async (path) => {
    const response = await fetch(`${url}${path}`)
    return [response.status, await response.text()]
  }

  assert.deepEqual(await body("/install.sh"), [200, "#!/bin/sh\necho install\n"])
  assert.deepEqual(await body("/codevisor-server-darwin-arm64.tar.gz"), [200, "archive"])
  assert.deepEqual(await body("/codevisor-server-darwin-arm64.tar.gz.sha256"), [200, "digest"])
  assert.equal((await body("/inputs.sha256"))[0], 404)
  assert.equal((await body("/../bun.lock"))[0], 404)
})

test("the server inputs key follows the compiled server, not unrelated files", async (t) => {
  const repoRoot = await fakeRepo(t)
  const before = await serverInputsKey(repoRoot, "darwin-arm64")

  await writeFile(join(repoRoot, "apps/www/public/index.html"), "<p>unrelated</p>\n")
  const unrelated = await serverInputsKey(repoRoot, "darwin-arm64")
  await writeFile(join(repoRoot, "packages/api/dist/index.js"), "export const changed = 1\n")
  const changed = await serverInputsKey(repoRoot, "darwin-arm64")

  assert.equal(unrelated, before)
  assert.notEqual(changed, before)
})

test("an archive built from the same server inputs is reused without rebuilding", async (t) => {
  const repoRoot = await fakeRepo(t)
  const archiveRoot = join(repoRoot, "archives")
  await mkdir(archiveRoot)
  const archive = join(archiveRoot, "codevisor-server-darwin-arm64.tar.gz")
  await writeFile(archive, "archive")
  await writeFile(
    join(archiveRoot, "inputs.sha256"),
    await serverInputsKey(repoRoot, "darwin-arm64")
  )

  assert.equal(await ensureDevServerArchive({ repoRoot, archiveRoot }), archive)
})
