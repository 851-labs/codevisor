import assert from "node:assert/strict"
import { mkdir, mkdtemp, readdir, rm, stat, utimes } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"

import { retainNetStamp } from "./net-artifact-retention.mjs"

const hour = 60 * 60 * 1000
const now = Date.parse("2026-11-06T12:00:00Z")

const entry = async (root, name, ageHours) => {
  const path = join(root, name)
  await mkdir(path)
  const date = new Date(now - ageHours * hour)
  await utimes(path, date, date)
}

test("using a build keeps it and the three most recently used others, and leaves non-build entries alone", async (t) => {
  const root = await mkdtemp(join(tmpdir(), "net-retention-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  const stamps = ["a", "b", "c", "d", "e", "f"].map((letter) => letter.repeat(16))
  for (const [age, stamp] of stamps.entries()) await entry(root, stamp, age + 1)
  await entry(root, "relay-0.35.0", 1000)
  await entry(root, "linux-cargo-home", 1000)
  const current = stamps.at(-1)

  const evicted = await retainNetStamp(root, current, now)

  assert.deepEqual(evicted.toSorted(), [stamps[3], stamps[4]])
  assert.deepEqual((await readdir(root)).toSorted(), [
    stamps[0],
    stamps[1],
    stamps[2],
    current,
    "linux-cargo-home",
    "relay-0.35.0"
  ])
  assert.equal((await stat(join(root, current))).mtimeMs, now)
})
