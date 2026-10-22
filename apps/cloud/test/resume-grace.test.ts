import { env, runInDurableObject } from "cloudflare:test"
import { expect, it } from "vitest"

import { ResumeSessions } from "../src/resume-sessions.js"

const graceMs = 60_000

const withSessions = (name: string, run: (sessions: ResumeSessions) => Promise<void>) =>
  runInDurableObject(env.USER_HUB.get(env.USER_HUB.idFromName(name)), (_hub, state) =>
    run(new ResumeSessions(state.storage.sql, graceMs))
  )

it("keeps the first grace deadline when a connection disconnects again", async () => {
  await withSessions("resume-grace-repeat", async (sessions) => {
    await sessions.register("conn", "app", "device", "key")

    expect(sessions.markDisconnected("conn", 1_000)).toBe(1_000 + graceMs)
    expect(sessions.markDisconnected("conn", 5_000)).toBe(1_000 + graceMs)
  })
})

it("gives a connection without a session no grace deadline", async () => {
  await withSessions("resume-grace-missing", async (sessions) => {
    expect(sessions.markDisconnected("missing", 1_000)).toBeUndefined()
  })
})

it("stops resuming a token once its grace deadline passes", async () => {
  await withSessions("resume-grace-expiry", async (sessions) => {
    const token = await sessions.register("conn", "app", "device", "key")
    const deadline = sessions.markDisconnected("conn", 1_000)!

    expect((await sessions.tryResume("app", token, deadline - 1))?.connection_id).toBe("conn")
    expect(await sessions.tryResume("app", token, deadline)).toBeUndefined()
  })
})
