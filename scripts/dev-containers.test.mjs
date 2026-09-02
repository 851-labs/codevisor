import assert from "node:assert/strict"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import {
  alignDevCloudCredentialUrl,
  devRemoteHomeMounts,
  syncLinuxWorkspace
} from "./dev-containers.mjs"

test("dev remotes persist root state and user workspaces independently", () => {
  assert.deepEqual(devRemoteHomeMounts("/tmp/remote-cloud"), [
    { host: "/tmp/remote-cloud/.container-home", container: "/root" },
    { host: "/tmp/remote-cloud/.container-users", container: "/home" }
  ])
})

const makeFakeRepo = async (root) => {
  await mkdir(join(root, "apps/server/dist"), { recursive: true })
  await mkdir(join(root, "packages/sync/dist"), { recursive: true })
  await mkdir(join(root, "packages/sync/src"), { recursive: true })
  await writeFile(join(root, "package.json"), '{"workspaces":["apps/*","packages/*"]}')
  await writeFile(join(root, "bun.lock"), "lock-v1")
  await writeFile(join(root, "apps/server/package.json"), '{"name":"server"}')
  await writeFile(join(root, "apps/server/dist/main.js"), "console.log(1)")
  await writeFile(join(root, "packages/sync/package.json"), '{"name":"sync"}')
  await writeFile(join(root, "packages/sync/dist/index.js"), "export {}")
  await writeFile(join(root, "packages/sync/src/index.ts"), "secret source")
}

test("syncLinuxWorkspace copies dists and manifests, never sources", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-devc-"))
  try {
    await makeFakeRepo(root)
    const containerRoot = join(root, "tmp/container")
    const first = await syncLinuxWorkspace(root, containerRoot)
    assert.equal(first.changed, true)
    assert.equal(
      await readFile(join(first.appRoot, "apps/server/dist/main.js"), "utf8"),
      "console.log(1)"
    )
    assert.equal(await readFile(join(first.appRoot, "bun.lock"), "utf8"), "lock-v1")
    // Sources never travel; the container needs dists + manifests only.
    await assert.rejects(readFile(join(first.appRoot, "packages/sync/src/index.ts")))

    // Unchanged workspace: the copy is skipped entirely.
    const second = await syncLinuxWorkspace(root, containerRoot)
    assert.equal(second.changed, false)

    // A dist rebuild re-syncs; a removed package's copy disappears.
    await writeFile(join(root, "apps/server/dist/main.js"), "console.log(2)")
    await rm(join(root, "packages/sync"), { recursive: true })
    const third = await syncLinuxWorkspace(root, containerRoot)
    assert.equal(third.changed, true)
    assert.equal(
      await readFile(join(third.appRoot, "apps/server/dist/main.js"), "utf8"),
      "console.log(2)"
    )
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test("alignDevCloudCredentialUrl preserves credentials while changing the runner route", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-devc-credential-"))
  const credentialsPath = join(root, "cloud.json")
  try {
    await writeFile(
      credentialsPath,
      JSON.stringify({ serverUrl: "http://localhost:4000", apiKey: "key", deviceId: "device" })
    )
    await alignDevCloudCredentialUrl(credentialsPath, "http://192.168.64.1:4000")
    assert.deepEqual(JSON.parse(await readFile(credentialsPath, "utf8")), {
      serverUrl: "http://192.168.64.1:4000",
      apiKey: "key",
      deviceId: "device"
    })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
