import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.ts"

const alive = async (pid: number) => (pid === process.pid ? { startedAt: "now" } : undefined)

const directories: Array<string> = []
const manifestPath = async () => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-runtime-test-"))
  directories.push(directory)
  return join(directory, "manifest.json")
}
afterEach(async () => {
  await Promise.all(
    directories.splice(0).map((directory) => rm(directory, { recursive: true, force: true }))
  )
})

describe("development runner claims", () => {
  it("won't let a second runner replace a live one", async () => {
    const path = await manifestPath()
    const manifest = { kind: "all", pid: process.pid, repoRoot: "/repo/cayenne" }

    await claimDevelopmentRunner(path, manifest, alive)

    await expect(claimDevelopmentRunner(path, manifest, alive)).rejects.toThrow(/already active/)
  })

  it("takes over a manifest whose owner is gone or unreadable", async () => {
    const path = await manifestPath()
    await writeFile(path, "not json")
    await claimDevelopmentRunner(path, { pid: process.pid, repoRoot: "/repo/cayenne" }, alive)
    await writeFile(path, `${JSON.stringify({ repoRoot: "/repo/quark" })}\n`)

    await claimDevelopmentRunner(path, { pid: process.pid, repoRoot: "/repo/cayenne" }, alive)

    expect(JSON.parse(await readFile(path, "utf8")).repoRoot).toBe("/repo/cayenne")
  })

  it("releases only the manifest it owns", async () => {
    const path = await manifestPath()
    const owner = { kind: "all", pid: process.pid, repoRoot: "/repo/cayenne" }
    const other = { kind: "all", pid: process.pid, repoRoot: "/repo/quark" }
    await writeFile(path, `${JSON.stringify(other)}\n`)

    await releaseDevelopmentRunner(path, owner)
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual(other)

    await releaseDevelopmentRunner(path, other)
    await expect(readFile(path)).rejects.toMatchObject({ code: "ENOENT" })
    await releaseDevelopmentRunner(path, other)
  })
})
