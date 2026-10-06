import { describe, expect, it, vi } from "vitest"

import { authFileCredential, makeOpenCode2Logins } from "./logins.js"
import type { OpenCodeServer } from "./server.js"

const attempt = {
  attemptID: "con_1",
  url: "https://auth.openai.com/codex/device",
  instructions: "Enter code: ABCD-1234",
  mode: "auto"
}

/// A scripted OpenCode server held for one flow; `released` settles when
/// the flow hands it back, which is how a test knows the flow ended.
const hold = (answers: (path: string, init?: { readonly method?: string }) => unknown) => {
  const calls: Array<[string, unknown]> = []
  let release!: () => void
  const released = new Promise<void>((resolve) => {
    release = resolve
  })
  const server = {
    url: "http://oc",
    stop: vi.fn(),
    request: vi.fn(async (path: string, init?: { readonly method?: string }) => {
      // Loading the location's integrations, before any sign-in.
      if (path === "/api/integration") return { data: [] }
      calls.push([path, init])
      const answer = answers(path, init)
      if (answer instanceof Error) throw answer
      return answer
    })
  } as unknown as OpenCodeServer
  return { hold: { server, release: vi.fn(() => release()) }, calls, released }
}

const immediately = async () => undefined
const never = () => new Promise<void>(() => undefined)
const statusPath = "/api/integration/openai/connect/oauth/con_1"

describe("OpenCode 2 sign-in", () => {
  it("relays OpenCode's sign-in, then captures the credential it saved", async () => {
    const statuses = ["pending", "complete"]
    const capture = vi.fn(async () => undefined)
    const waits: number[] = []
    const logins = makeOpenCode2Logins({
      wait: async (ms) => {
        waits.push(ms)
      }
    })
    const h = hold((path) => {
      if (path.endsWith("/connect/oauth")) return { data: attempt }
      if (path === statusPath) return { data: { status: statuses.shift() } }
      return {
        data: [
          { integrationID: "xai", active: true, value: { type: "oauth" } },
          {
            integrationID: "openai",
            active: true,
            value: {
              type: "oauth",
              methodID: "chatgpt-headless",
              refresh: "r",
              access: "a",
              expires: 5,
              metadata: { accountID: "acct" }
            }
          }
        ]
      }
    })
    const flow = await logins.begin(h.hold, "/home", {
      accountId: "default",
      providerId: "openai",
      methodId: "chatgpt-headless",
      inputs: { plan: "plus" },
      capture
    })
    expect(flow).toMatchObject({
      state: "running",
      authorization: { url: attempt.url, method: "auto", instructions: attempt.instructions }
    })
    expect(h.calls[0]).toEqual([
      "/api/integration/openai/connect/oauth",
      { location: "/home", body: { methodID: "chatgpt-headless", answer: { plan: "plus" } } }
    ])
    await h.released
    expect(logins.flow(flow.id)?.state).toBe("complete")
    expect(capture).toHaveBeenCalledWith({
      type: "oauth",
      refresh: "r",
      access: "a",
      expires: 5,
      accountId: "acct"
    })
    expect(waits).toEqual([1_000, 1_000])
  })

  it("ends a sign-in that OpenCode reports failed, expired, or saved nothing for, with a reason", async () => {
    const run = async (answers: (path: string) => unknown, capture?: () => Promise<void>) => {
      const logins = makeOpenCode2Logins({ wait: immediately })
      const h = hold((path) =>
        path.endsWith("/connect/oauth") ? { data: attempt } : answers(path)
      )
      const flow = await logins.begin(h.hold, "/home", {
        accountId: "default",
        providerId: "openai",
        methodId: "chatgpt-browser",
        ...(capture ? { capture } : {})
      })
      await h.released
      return logins.flow(flow.id)
    }
    expect(await run(() => ({ data: { status: "expired" } }))).toMatchObject({
      state: "error",
      error: "Sign-in timed out. Try again."
    })
    expect(
      await run(() => ({ data: { status: "failed", message: "access_denied" } }))
    ).toMatchObject({
      error: "access_denied"
    })
    expect(await run(() => ({ data: { status: "failed" } }))).toMatchObject({
      error: "Sign-in failed."
    })
    expect(await run(() => new Error("connection reset"))).toMatchObject({
      error: "connection reset"
    })
    expect(
      await run(
        (path) => (path === statusPath ? { data: { status: "complete" } } : { data: [] }),
        async () => undefined
      )
    ).toMatchObject({
      state: "error",
      error: "OpenCode finished signing in but saved no credential."
    })
    // Without a capture, the credential stays where OpenCode saved it.
    expect(await run(() => ({ data: { status: "complete" } }))).toMatchObject({ state: "complete" })
  })

  it("saves an API key directly and gives the server back", async () => {
    const logins = makeOpenCode2Logins({ wait: never })
    const h = hold(() => undefined)
    const flow = await logins.begin(h.hold, "/home", {
      accountId: "default",
      providerId: "openrouter",
      methodId: "key",
      apiKey: "sk-or"
    })
    expect(flow).toMatchObject({ state: "complete" })
    expect(h.calls).toEqual([
      ["/api/integration/openrouter/connect/key", { location: "/home", body: { key: "sk-or" } }]
    ])
    expect(h.hold.release).toHaveBeenCalledOnce()
  })

  it("passes a pasted code on, and cancels an attempt in OpenCode", async () => {
    const logins = makeOpenCode2Logins({ wait: never })
    let rejectCode = false
    const h = hold((path) => {
      if (path.endsWith("/connect/oauth")) return { data: { ...attempt, mode: "code" } }
      if (path.endsWith("/complete") && rejectCode) return new Error("invalid code")
      return undefined
    })
    const flow = await logins.begin(h.hold, "/home", {
      accountId: "default",
      providerId: "openai",
      methodId: "chatgpt-browser"
    })
    expect(flow.authorization?.method).toBe("code")
    await logins.answer(flow.id, "the-code")
    expect(h.calls.at(-1)).toEqual([
      `${statusPath}/complete`,
      { location: "/home", body: { code: "the-code" } }
    ])
    expect(await logins.cancel(flow.id)).toBe(true)
    expect(h.calls.at(-1)).toEqual([statusPath, { location: "/home", method: "DELETE" }])
    expect(logins.flow(flow.id)).toBeUndefined()
    expect(await logins.cancel(flow.id)).toBe(false)
    expect(await logins.answer(flow.id, "late")).toBeUndefined()

    const rejected = hold((path) => {
      if (path.endsWith("/connect/oauth")) return { data: attempt }
      return rejectCode ? new Error("invalid code") : undefined
    })
    rejectCode = true
    const second = await logins.begin(rejected.hold, "/home", {
      accountId: "default",
      providerId: "openai",
      methodId: "chatgpt-browser"
    })
    expect(await logins.answer(second.id, "wrong")).toMatchObject({
      state: "error",
      error: "invalid code"
    })
    expect(await logins.answer(second.id, "again")).toMatchObject({ state: "error" })
    // An ended flow is only forgotten.
    expect(await logins.cancel(second.id)).toBe(true)
    expect(
      rejected.calls.filter(([, init]) => (init as { method?: string })?.method === "DELETE")
    ).toEqual([])
  })

  it("gives the server back when OpenCode refuses to start a sign-in", async () => {
    const logins = makeOpenCode2Logins({ wait: never })
    const h = hold(() => new Error("Unknown method"))
    await expect(
      logins.begin(h.hold, "/home", {
        accountId: "default",
        providerId: "openai",
        methodId: "nope"
      })
    ).rejects.toThrow("Unknown method")
    expect(h.hold.release).toHaveBeenCalledOnce()
  })

  it("reads OpenCode 2's credential in auth.json's shape", () => {
    expect(
      authFileCredential({
        refresh: "r",
        access: "a",
        expires: 1,
        metadata: { enterpriseUrl: "ghe.test" }
      })
    ).toEqual({ type: "oauth", refresh: "r", access: "a", expires: 1, enterpriseUrl: "ghe.test" })
    expect(authFileCredential({ refresh: "r", access: "a", expires: 1 })).toEqual({
      type: "oauth",
      refresh: "r",
      access: "a",
      expires: 1
    })
  })
})
