import { env, runInDurableObject } from "cloudflare:test"
import { expect, it, vi } from "vitest"

import { ResumeSessions } from "../src/resume-sessions.js"

it("one resume token can adopt its identity only once during concurrent rotation", async () => {
  const namespace = env.USER_HUB as unknown as DurableObjectNamespace
  const stub = namespace.get(namespace.idFromName("resume-token-ownership"))
  await runInDurableObject(stub, async (_hub, state) => {
    const sessions = new ResumeSessions(state.storage.sql, 60_000)
    const token = await sessions.register("original", "app", "device", "key")
    let signalEntered!: () => void
    const entered = new Promise<void>((resolve) => {
      signalEntered = resolve
    })
    let signalRelease!: () => void
    const release = new Promise<void>((resolve) => {
      signalRelease = resolve
    })
    const digest = crypto.subtle.digest.bind(crypto.subtle)
    let rotations = 0
    vi.spyOn(crypto.subtle, "digest").mockImplementation(async (algorithm, data) => {
      if (new TextDecoder().decode(data) !== token) {
        if (++rotations === 2) signalEntered()
        await release
      }
      return digest(algorithm, data)
    })
    const attempts = Promise.all(
      ["first", "second"].map((id) =>
        sessions.adoptOrRegister(id, "app", { deviceId: "device", publicKey: "key" }, token)
      )
    )
    try {
      await entered
      signalRelease()
      const results = await attempts
      expect(results.filter((result) => result.resumed)).toHaveLength(1)
      expect(new Set(results.map((result) => result.connectionId)).size).toBe(2)
      const resumed = results.find((result) => result.resumed)!
      expect((await sessions.tryResume("app", resumed.token, Date.now()))?.connection_id).toBe(
        "original"
      )
    } finally {
      signalRelease()
      await attempts
      vi.restoreAllMocks()
    }
  })
})
