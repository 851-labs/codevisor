import assert from "node:assert/strict"
import { mkdir, mkdtemp, readdir, rm, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { ensureStoreEntry, pruneStore, STORE_RETENTION_MS } from "./apfs-clone.mjs"

async function temporaryStore(t) {
  const root = await mkdtemp(join(tmpdir(), "codevisor-apfs-clone-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  return join(root, "store")
}

test("concurrent populations publish one store entry", async (t) => {
  const store = await temporaryStore(t)

  const entries = await Promise.all(
    ["first", "second", "third"].map((writer) =>
      ensureStoreEntry(store, "entry", (staging) => writeFile(join(staging, writer), writer))
    )
  )

  assert.deepEqual(new Set(entries), new Set([join(store, "entry")]))
  assert.equal((await readdir(join(store, "entry"))).length, 1)
  assert.deepEqual(await readdir(store), ["entry"])
})

test("pruning removes long-unused entries and abandoned staging only", async (t) => {
  const store = await temporaryStore(t)
  const now = Date.parse("2026-10-01T00:00:00Z")
  const age = async (name, milliseconds) => {
    await mkdir(join(store, name), { recursive: true })
    const at = new Date(now - milliseconds)
    await utimes(join(store, name), at, at)
  }
  const hour = 60 * 60 * 1000
  await age("stale", STORE_RETENTION_MS + hour)
  await age("recent", STORE_RETENTION_MS - hour)
  await age("kept", STORE_RETENTION_MS + hour)
  await age(".incoming-crashed", 25 * hour)
  await age(".incoming-in-progress", hour)
  await age(".hidden", STORE_RETENTION_MS + hour)

  const removed = await pruneStore(store, now, new Set(["kept"]))

  assert.deepEqual(removed.toSorted(), [".incoming-crashed", "stale"])
  assert.deepEqual((await readdir(store)).toSorted(), [
    ".hidden",
    ".incoming-in-progress",
    "kept",
    "recent"
  ])
})
