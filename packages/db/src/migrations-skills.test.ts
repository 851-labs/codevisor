import Database from "better-sqlite3"
import { expect, it } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

it("drops the old skill replica locally and keeps every other namespace", async () => {
  const filename = tempDatabase()
  const current = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    const timestamp = { counter: 0, deviceId: "device-a", wallMs: 10 }
    for (const namespace of [
      "skills",
      "local.skills-applied",
      "skill-readiness",
      "codevisor-skills",
      "mcps"
    ]) {
      await run(current.mergeSyncEntries(namespace, [{ key: "deploy", timestamp, value: "x" }]))
    }
  } finally {
    await run(current.close)
  }
  const legacy = new Database(filename)
  try {
    legacy.exec("delete from schema_migrations where id = 58")
  } finally {
    legacy.close()
  }

  const upgraded = await run(makeDatabase({ filename, serverId: "local" }))
  try {
    for (const dropped of ["skills", "local.skills-applied", "skill-readiness"]) {
      expect(await run(upgraded.getSyncEntries(dropped))).toEqual([])
    }
    for (const kept of ["codevisor-skills", "mcps"]) {
      expect(await run(upgraded.getSyncEntries(kept))).toHaveLength(1)
    }
  } finally {
    await run(upgraded.close)
  }
})
