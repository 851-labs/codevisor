import assert from "node:assert/strict"
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import process from "node:process"
import test from "node:test"

import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.mjs"

test("an active worktree runner cannot be replaced", async () => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-runtime-test-"))
  const manifestPath = join(directory, "manifest.json")
  const manifest = { kind: "all", pid: process.pid, repoRoot: "/repo/cayenne" }

  try {
    await claimDevelopmentRunner(manifestPath, manifest)
    await assert.rejects(claimDevelopmentRunner(manifestPath, manifest), /already active/)
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})

test("a runner releases only the manifest it owns", async () => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-runtime-test-"))
  const manifestPath = join(directory, "manifest.json")
  const owner = { kind: "all", pid: process.pid, repoRoot: "/repo/cayenne" }
  const other = { kind: "all", pid: process.pid, repoRoot: "/repo/quark" }

  try {
    await writeFile(manifestPath, `${JSON.stringify(other)}\n`)
    await releaseDevelopmentRunner(manifestPath, owner)
    assert.deepEqual(JSON.parse(await readFile(manifestPath, "utf8")), other)

    await releaseDevelopmentRunner(manifestPath, other)
    await assert.rejects(readFile(manifestPath), { code: "ENOENT" })
  } finally {
    await rm(directory, { recursive: true, force: true })
  }
})
