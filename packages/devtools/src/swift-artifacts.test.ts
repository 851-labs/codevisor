import assert from "node:assert/strict"
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  rm,
  symlink,
  utimes,
  writeFile
} from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { onTestFinished, test } from "vitest"

import { prepareSwiftArtifacts } from "./swift-artifacts.ts"

const darwinOnly = { skip: process.platform !== "darwin" }
const checksum = "85cfef48d8a6508af9c645a6887a13ec0ba38a71316195a1d0d9c9c3f051f013"

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "codevisor-swift-artifacts-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  return root
}

async function worktree(
  root: string,
  name: string,
  { binary = "sentry-binary", unpackedAt = new Date("2026-01-02T03:04:05Z") } = {}
) {
  const stateDirectory = join(root, name, "SourcePackages")
  const artifact = join(stateDirectory, "artifacts/sentry/Sentry/Sentry.xcframework")
  const local = join(root, name, "Frameworks/CodevisorNetFFI.xcframework")
  const pins = join(root, name, "Package.resolved")
  await mkdir(dirname(pins), { recursive: true })
  await writeFile(pins, "pins v1")
  const extract = async () => {
    const framework = join(artifact, "macos-arm64/Sentry.framework")
    await mkdir(join(framework, "Versions/A"), { recursive: true })
    await writeFile(join(artifact, "Info.plist"), "plist")
    await writeFile(join(framework, "Versions/A/Sentry"), binary)
    await symlink("Versions/A/Sentry", join(framework, "Sentry"))
    await utimes(join(framework, "Versions/A/Sentry"), unpackedAt, unpackedAt)
    await mkdir(local, { recursive: true })
    await writeFile(
      join(stateDirectory, "workspace-state.json"),
      JSON.stringify({
        version: 7,
        object: {
          artifacts: [
            { path: artifact, source: { checksum } },
            { path: local, source: { type: "local" } }
          ]
        }
      })
    )
  }
  let resolutions = 0
  const resolve = async () => {
    resolutions += 1
    if (!(await exists(artifact))) await extract()
  }
  return {
    artifact,
    unpackedAt,
    binaryPath: join(artifact, "macos-arm64/Sentry.framework/Versions/A/Sentry"),
    pins,
    stateDirectory,
    extract,
    resolutions: () => resolutions,
    prepare: (
      store: string,
      log: (message: string) => void = () => assert.fail("unexpected warning")
    ) => prepareSwiftArtifacts({ stateDirectory, store, inputs: [pins], resolve, log })
  }
}

async function exists(path: string) {
  return lstat(path).then(
    () => true,
    () => false
  )
}

test(
  "resolution shares downloaded artifacts through the machine-wide store",
  darwinOnly,
  async () => {
    const root = await fixture()
    const store = join(root, "store")
    const first = await worktree(root, "biscotti")
    const second = await worktree(root, "grouper", { unpackedAt: new Date("2026-03-04T05:06:07Z") })

    assert.deepEqual((await first.prepare(store)).shared, [first.artifact])
    assert.deepEqual((await second.prepare(store)).shared, [second.artifact])

    for (const { binaryPath, artifact, unpackedAt } of [first, second]) {
      assert.equal(await readFile(binaryPath, "utf8"), "sentry-binary")
      assert.equal((await lstat(binaryPath)).mtime.getTime(), unpackedAt.getTime())
      assert.equal(
        await readlink(join(artifact, "macos-arm64/Sentry.framework/Sentry")),
        "Versions/A/Sentry"
      )
    }
    const stored = join(store, `${checksum}-Sentry.xcframework`, "Sentry.xcframework")
    assert.equal(
      await readFile(join(stored, "macos-arm64/Sentry.framework/Versions/A/Sentry"), "utf8"),
      "sentry-binary"
    )
  }
)

test("unchanged pins skip resolution until they or the unpacked files change", async () => {
  const root = await fixture()
  const store = join(root, "store")
  const checkout = await worktree(root, "biscotti")

  assert.equal((await checkout.prepare(store)).resolved, true)
  assert.equal((await checkout.prepare(store)).resolved, false)
  assert.equal(checkout.resolutions(), 1)

  await writeFile(checkout.pins, "pins v2")
  assert.equal((await checkout.prepare(store)).resolved, true)
  assert.equal(checkout.resolutions(), 2)

  await rm(checkout.artifact, { recursive: true })
  await checkout.extract()
  assert.equal((await checkout.prepare(store)).resolved, true)
  assert.equal(checkout.resolutions(), 3)
})

test("an artifact that differs from the stored copy keeps its own files", darwinOnly, async () => {
  const root = await fixture()
  const store = join(root, "store")
  await (await worktree(root, "biscotti")).prepare(store)
  const corrupt = await worktree(root, "grouper", { binary: "truncated" })
  const warnings: Array<string> = []

  const result = await corrupt.prepare(store, (message) => warnings.push(message))

  assert.deepEqual(result.shared, [])
  assert.equal(await readFile(corrupt.binaryPath, "utf8"), "truncated")
  assert.equal(warnings.length, 1)
  assert.match(warnings[0] ?? "", /could not share Swift artifact .*Sentry\.xcframework.*changed/)
})
