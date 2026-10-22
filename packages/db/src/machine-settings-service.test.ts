import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { FIRST_RUN_PROJECTS_SETTING, makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("machine settings", () => {
  it("stores, replaces, and clears a setting across restarts", async () => {
    const filename = tempDatabase()
    let db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(await run(db.getMachineSetting("clone-folder"))).toBeUndefined()
      await run(db.setMachineSetting("clone-folder", "/srv/one"))
      await run(db.setMachineSetting("clone-folder", "/srv/two"))
      await run(db.close)
      db = await run(makeDatabase({ filename, serverId: "local" }))
      expect(await run(db.getMachineSetting("clone-folder"))).toBe("/srv/two")
      await run(db.setMachineSetting("clone-folder", undefined))
      expect(await run(db.getMachineSetting("clone-folder"))).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })

  it("marks only a newly created database for first-run projects", async () => {
    const filename = tempDatabase()
    let db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(await run(db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING))).toBe("pending")
      await run(db.close)
      db = await run(makeDatabase({ filename, serverId: "local" }))
      expect(await run(db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING))).toBe("pending")
    } finally {
      await run(db.close)
    }
  })

  it("leaves a database from before first-run projects unmarked", async () => {
    const filename = tempDatabase()
    await run((await run(makeDatabase({ filename, serverId: "local" }))).close)
    const sqlite = new Database(filename)
    sqlite.prepare("delete from instance_meta where key like 'machine-setting:%'").run()
    sqlite.close()

    const db = await run(makeDatabase({ filename, serverId: "local" }))
    try {
      expect(await run(db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING))).toBeUndefined()
    } finally {
      await run(db.close)
    }
  })
})
