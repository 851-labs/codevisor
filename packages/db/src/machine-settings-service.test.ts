import { describe, expect, it } from "vitest"

import { makeDatabase } from "./index.js"
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
})
