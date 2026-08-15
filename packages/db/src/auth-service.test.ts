import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("persists a stable instance id across reopens", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const first = await run(db.getOrCreateInstanceId)
    expect(first).toMatch(/^[0-9a-f-]{36}$/)
    expect(await run(db.getOrCreateInstanceId)).toBe(first)
    await run(db.close)

    const reopened = await run(makeDatabase({ filename, serverId: "renamed" }))
    expect(await run(reopened.getOrCreateInstanceId)).toBe(first)
    await run(reopened.close)
  })

  it("keeps the connection token stable across reopens and rotates on demand", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    const token = await run(db.getOrCreateConnectionToken)
    expect(token).toMatch(/^hm_/)
    // Stable within a run and verifiable as a bearer token.
    expect(await run(db.getOrCreateConnectionToken)).toBe(token)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    await run(db.close)

    // Survives a restart/update (reopen with a different serverId).
    const reopened = await run(makeDatabase({ filename, serverId: "renamed" }))
    expect(await run(reopened.getOrCreateConnectionToken)).toBe(token)

    // Rotation issues a new token and retires the old one.
    const rotated = await run(reopened.rotateConnectionToken)
    expect(rotated).not.toBe(token)
    expect(await run(reopened.getOrCreateConnectionToken)).toBe(rotated)
    expect(await run(reopened.verifyBearerToken(rotated))).toBe(true)
    expect(await run(reopened.verifyBearerToken(token))).toBe(false)
    await run(reopened.close)
  })

  it("can rotate a connection token that was never issued", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const token = await run(db.rotateConnectionToken)
    expect(token).toMatch(/^hm_/)
    expect(await run(db.verifyBearerToken(token))).toBe(true)
    await run(db.close)
  })

  it("persists and clears the preferred Browser Use backend", async () => {
    const filename = tempDatabase()
    const db = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(db.getBrowserPreference)).toBeUndefined()
    await run(db.setBrowserPreference("chrome"))
    expect(await run(db.getBrowserPreference)).toBe("chrome")
    await run(db.close)

    const reopened = await run(makeDatabase({ filename, serverId: "renamed" }))
    expect(await run(reopened.getBrowserPreference)).toBe("chrome")
    await run(reopened.setBrowserPreference("managed"))
    expect(await run(reopened.getBrowserPreference)).toBe("managed")
    await run(reopened.setBrowserPreference(undefined))
    expect(await run(reopened.getBrowserPreference)).toBeUndefined()
    await run(reopened.close)
  })
})
