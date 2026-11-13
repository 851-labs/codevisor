import type { DataUpgradeProgress } from "@codevisor/api"
import Database from "better-sqlite3"
import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

const turnOffSpaceRelease = (filename: string): void => {
  const sqlite = new Database(filename)
  try {
    sqlite.pragma("auto_vacuum = NONE")
    sqlite.exec("vacuum")
  } finally {
    sqlite.close()
  }
}

const freePages = (filename: string): number => {
  const sqlite = new Database(filename, { readonly: true })
  try {
    return Number(sqlite.pragma("freelist_count", { simple: true }))
  } finally {
    sqlite.close()
  }
}

describe("database space", () => {
  it("compacts an older database once, then gives deleted space back to the disk", async () => {
    const filename = tempDatabase()
    await run((await run(makeDatabase({ filename, serverId: "local" }))).close)
    turnOffSpaceRelease(filename)
    const progress: Array<DataUpgradeProgress> = []

    const db = await run(
      makeDatabase({ filename, serverId: "local", onDataUpgradeProgress: (p) => progress.push(p) })
    )
    onTestFinished(() => run(db.close))
    const file = await run(
      db.createFile("big.bin", "application/octet-stream", "file", Buffer.alloc(2_000_000, 1))
    )
    await run(db.deleteFiles([file.id]))
    await run(db.releaseFreeSpace)

    expect(progress.filter((p) => p.name === "Freeing up disk space").map((p) => p.state)).toEqual([
      "running",
      "completed"
    ])
    expect(freePages(filename)).toBe(0)
  })
})
