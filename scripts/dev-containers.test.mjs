import assert from "node:assert/strict"
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { syncLinuxWorkspace } from "./dev-container-workspace.mjs"
import {
  alignDevCloudCredentialUrl,
  sweepStaleContainers,
  devRemoteHomeMounts
} from "./dev-containers.mjs"

for (const engine of ["apple", "docker"]) {
  test(`${engine} cleanup matches the exact worktree label`, async () => {
    const calls = []
    const entries =
      engine === "apple"
        ? [
            { configuration: { id: "ours", labels: { "dev.codevisor.worktree": "abc" } } },
            { configuration: { id: "other", labels: { "dev.codevisor.worktree": "abcdef" } } }
          ]
        : [
            { ID: "ours", Labels: "x=y,dev.codevisor.worktree=abc" },
            { ID: "other", Labels: "dev.codevisor.worktree=abcdef" },
            { ID: "unrelated", Labels: "other.label=abc" }
          ]
    await sweepStaleContainers(engine, "abc", async (binary, args) => {
      calls.push([binary, args])
      return engine === "apple"
        ? JSON.stringify(entries)
        : entries.map((entry) => JSON.stringify(entry)).join("\n")
    })
    assert.deepEqual(calls.at(-1), [
      engine === "apple" ? "container" : "docker",
      ["rm", "--force", "ours"]
    ])
    assert.equal(calls.length, 2)
    if (engine === "docker")
      assert.deepEqual(calls[0][1], ["ps", "--all", "--format", "{{json .}}"])
  })
}

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
  await mkdir(join(root, "packages/sync/resources"), { recursive: true })
  await writeFile(join(root, "package.json"), '{"workspaces":["apps/*","packages/*"]}')
  await writeFile(join(root, "bun.lock"), "lock-v1")
  await writeFile(join(root, "apps/server/package.json"), '{"name":"server"}')
  await writeFile(join(root, "apps/server/dist/main.js"), "console.log(1)")
  await writeFile(join(root, "packages/sync/package.json"), '{"name":"sync"}')
  await writeFile(join(root, "packages/sync/dist/index.js"), "export {}")
  await writeFile(join(root, "packages/sync/src/index.ts"), "secret source")
  await writeFile(join(root, "packages/sync/resources/runtime.wasm"), "wasm-v1")
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
    // Runtime resources travel with the dist that reads them.
    assert.equal(
      await readFile(join(first.appRoot, "packages/sync/resources/runtime.wasm"), "utf8"),
      "wasm-v1"
    )
    // Sources never travel; the container needs dists + manifests only.
    await assert.rejects(readFile(join(first.appRoot, "packages/sync/src/index.ts")))

    // Unchanged workspace: the copy is skipped entirely.
    const second = await syncLinuxWorkspace(root, containerRoot)
    assert.equal(second.changed, false)

    // A resource change alone re-syncs.
    await writeFile(join(root, "packages/sync/resources/runtime.wasm"), "wasm-v2")
    const resourced = await syncLinuxWorkspace(root, containerRoot)
    assert.equal(resourced.changed, true)
    assert.equal(
      await readFile(join(resourced.appRoot, "packages/sync/resources/runtime.wasm"), "utf8"),
      "wasm-v2"
    )

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

test("alignDevCloudCredentialUrl rebinds shared accounts to the dev cloud's current route", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-devc-credential-"))
  const shared = join(root, "shared-credentials")
  const credentialsPath = join(root, "cloud.json")
  try {
    await mkdir(shared)
    // cloud.json already follows the route (an earlier run aligned it); the accounts don't yet.
    await writeFile(credentialsPath, JSON.stringify({ serverUrl: "http://192.168.64.1:4000" }))
    const sameCloud = { cloud: "http://localhost:4000", account: "account", record: { v: 1 } }
    const otherCloud = { cloud: "https://cloud.example.com", account: "account" }
    await writeFile(join(shared, "a.json"), JSON.stringify(sameCloud))
    await writeFile(join(shared, "b.json"), JSON.stringify(otherCloud))
    await writeFile(join(shared, "c.json"), JSON.stringify({ account: "local-only" }))

    await alignDevCloudCredentialUrl(credentialsPath, "http://192.168.64.1:4000/")

    const read = async (name) => JSON.parse(await readFile(join(shared, name), "utf8"))
    assert.deepEqual(await read("a.json"), { ...sameCloud, cloud: "http://192.168.64.1:4000" })
    assert.deepEqual(await read("b.json"), otherCloud)
    assert.deepEqual(await read("c.json"), { account: "local-only" })
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})
