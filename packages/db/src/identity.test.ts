import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { resolveServerIdentity } from "./identity.js"
import { run, tempDatabase } from "./test-support.js"
import { Effect } from "effect"

describe("resolveServerIdentity", () => {
  it("mints once and returns the same identity forever after", () => {
    const filename = tempDatabase()
    const first = resolveServerIdentity(filename)
    expect(resolveServerIdentity(filename)).toBe(first)
  })

  it("shares the identity row with getOrCreateInstanceId", async () => {
    const filename = tempDatabase()
    const minted = resolveServerIdentity(filename)
    const db = await run(makeDatabase({ filename, serverId: minted }))
    expect(await run(db.getOrCreateInstanceId)).toBe(minted)
    await Effect.runPromise(db.close)
  })
})
