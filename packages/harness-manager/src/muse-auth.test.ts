import type { MuseClient, MuseSpawnRequest } from "@codevisor/adapter-muse"
import type { HarnessAccount } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import type { HarnessAuthCore } from "./harness-auth-core.js"
import { makeMuseAuth } from "./muse-auth.js"

const host = (replies: Record<string, unknown> = {}) => {
  const requests: Array<{ method: string; params: unknown }> = []
  let notification: ((method: string, params: unknown) => void) | undefined
  const state = { closed: false }
  const client: MuseClient = {
    request: async <T>(method: string, params?: unknown) => {
      requests.push({ method, params })
      const reply =
        {
          initialize: { serverInfo: { version: "1.4.7" } },
          "account/loginStart": { verificationUrl: "https://meta.ai/device", userCode: "WXYZ" },
          ...replies
        }[method] ?? {}
      if (reply instanceof Error) throw reply
      return reply as T
    },
    notify: () => undefined,
    onNotification: (handler) => {
      notification = handler
    },
    onRequest: () => undefined,
    onClose: () => undefined,
    close: () => {
      state.closed = true
    }
  }
  return {
    client,
    state,
    requests,
    methods: () => requests.map((entry) => entry.method),
    complete: (outcome: string) => notification?.("account/loginCompleted", { outcome })
  }
}

const account = (fields: Partial<HarnessAccountRecord> = {}) =>
  ({
    id: "acct-1",
    harnessId: "muse-code",
    profileKind: "default",
    ...fields
  }) as HarnessAccountRecord

const setup = (
  options: {
    shared?: "absent" | "empty" | "broken"
    deadlineMs?: number
    probeError?: Error
    signedIn?: boolean
    captureError?: Error
    profile?: string
    home?: string
    replies?: Record<string, unknown>
  } = {}
) => {
  const hosts: Array<ReturnType<typeof host>> = []
  const spawned: Array<MuseSpawnRequest> = []
  const events: Array<{ kind: string; payload: unknown }> = []
  const loginFailed = vi.fn(async () => {
    if (options.shared === "broken") throw new Error("sync offline")
  })
  const captureLogin = vi.fn(async () => {
    if (options.captureError !== undefined) throw options.captureError
  })
  const saveApiKey = vi.fn(async () => undefined)
  const setActive = vi.fn(() => Effect.void)
  const probe = vi.fn(async () => {
    if (options.probeError !== undefined) throw options.probeError
    return {
      authState: options.signedIn === false ? "unauthenticated" : "authenticated"
    } as HarnessAccount
  })
  const core = {
    accountEnv: async () => (options.home === undefined ? {} : { HOME: options.home }),
    executable: async (harnessId: string) => `/bin/${harnessId}`,
    profilePath: () => options.profile,
    emit: (event: { kind: string; payload: unknown }) => events.push(event),
    config: {
      db: { setActiveHarnessAccount: setActive },
      ...(options.shared === "absent"
        ? {}
        : {
            sharedAccounts: () =>
              options.shared === "empty" ? undefined : { loginFailed, captureLogin, saveApiKey }
          })
    }
  } as unknown as HarnessAuthCore
  const auth = makeMuseAuth(
    core,
    probe,
    async (request) => {
      spawned.push(request)
      const next = host(options.replies)
      hosts.push(next)
      return next.client
    },
    options.deadlineMs
  )
  const completed = () =>
    new Promise<unknown>((resolve) => {
      const push = events.push.bind(events)
      events.push = (...added) => {
        const length = push(...added)
        for (const event of added)
          if ((event.payload as { completed?: boolean }).completed === true) resolve(event.payload)
        return length
      }
    })
  return {
    auth,
    hosts,
    spawned,
    events,
    probe,
    setActive,
    loginFailed,
    captureLogin,
    saveApiKey,
    completed
  }
}

describe("Muse Code sign-in", () => {
  it("hands out Muse's device code and activates the account once Muse grants it", async () => {
    const { auth, hosts, spawned, events, probe, setActive, completed } = setup({
      home: "/home/me",
      shared: "empty"
    })
    const flow = await auth.begin(account(), "deviceCode", undefined)
    expect(flow).toEqual({
      id: expect.any(String),
      accountId: "acct-1",
      kind: "deviceCode",
      verificationUrl: "https://meta.ai/device",
      userCode: "WXYZ"
    })
    expect(spawned).toEqual([
      {
        command: "/bin/muse-code",
        args: ["--no-session-log"],
        cwd: "/home/me",
        env: { HOME: "/home/me" }
      }
    ])
    expect(hosts[0]!.methods()).toEqual(["initialize", "account/loginStart"])
    expect(hosts[0]!.requests[1]!.params).toEqual({ type: "deviceCode" })
    expect(events).toEqual([
      { kind: "harness.authFlow.updated", subjectId: "muse-code", payload: flow }
    ])
    expect(hosts[0]!.state.closed).toBe(false)

    const done = completed()
    hosts[0]!.complete("granted")
    await expect(done).resolves.toEqual({
      id: flow.id,
      accountId: "acct-1",
      completed: true,
      success: true
    })
    expect(hosts[0]!.state.closed).toBe(true)
    expect(probe).toHaveBeenCalledWith("acct-1", true)
    expect(setActive).toHaveBeenCalledWith("muse-code", "acct-1")
  })

  it("reports a declined or unverifiable sign-in as failed", async () => {
    const declined = setup()
    await declined.auth.begin(account(), undefined, undefined)
    const denied = declined.completed()
    declined.hosts[0]!.complete("denied")
    await expect(denied).resolves.toMatchObject({ success: false })
    expect(declined.probe).not.toHaveBeenCalled()
    expect(declined.loginFailed).toHaveBeenCalledWith("acct-1")

    const unverified = setup({ signedIn: false, shared: "empty" })
    await unverified.auth.begin(account(), "deviceCode", undefined)
    const done = unverified.completed()
    unverified.hosts[0]!.complete("granted")
    await expect(done).resolves.toMatchObject({ success: false })
    expect(unverified.setActive).not.toHaveBeenCalled()

    const broken = setup({ probeError: new Error("db locked"), shared: "absent" })
    await broken.auth.begin(account(), "deviceCode", undefined)
    const ended = broken.completed()
    broken.hosts[0]!.complete("granted")
    await expect(ended).resolves.toMatchObject({ success: false })
    const unshared = setup({ shared: "empty" })
    const flow = await unshared.auth.begin(account(), "deviceCode", undefined)
    await unshared.auth.cancel(flow.id)
    expect(unshared.hosts[0]!.state.closed).toBe(true)
    await unshared.auth.begin(account({ id: "acct-2" }), "deviceCode", undefined)
    await unshared.auth.begin(account(), "deviceCode", undefined)
    expect(unshared.hosts[1]!.methods()).not.toContain("account/loginCancel")
    const refused = unshared.completed()
    unshared.hosts[1]!.complete("denied")
    await expect(refused).resolves.toMatchObject({ accountId: "acct-2", success: false })
    const offline = setup({ shared: "broken" })
    await offline.auth.begin(account(), "deviceCode", undefined)
    const unreported = offline.completed()
    offline.hosts[0]!.complete("denied")
    await expect(unreported).resolves.toMatchObject({ success: false })
    const unsynced = setup({ shared: "absent" })
    await unsynced.auth.begin(account(), "deviceCode", undefined)
    const lapsed = unsynced.completed()
    unsynced.hosts[0]!.complete("expired")
    await expect(lapsed).resolves.toMatchObject({ success: false })
  })

  it("starts each host in the account's profile, else its home, else here", async () => {
    const profiled = setup({
      profile: "/profiles/a",
      home: "/home/me",
      replies: { "account/loginStart": {} }
    })
    const flow = await profiled.auth.begin(account(), "deviceCode", undefined)
    expect(profiled.spawned[0]!.cwd).toBe("/profiles/a")
    expect(flow).toMatchObject({ verificationUrl: "https://dev.meta.ai", userCode: "" })
    const bare = setup()
    await bare.auth.logout(account())
    expect(bare.spawned[0]!.cwd).toBe(process.cwd())
  })

  it("cancels a pending flow, including one replaced by a new attempt", async () => {
    const { auth, hosts, events, loginFailed } = setup()
    const first = await auth.begin(account(), "deviceCode", undefined)
    await auth.begin(account(), "deviceCode", undefined)
    expect(hosts[0]!.methods()).toContain("account/loginCancel")
    expect(hosts[0]!.state.closed).toBe(true)
    hosts[0]!.complete("cancelled")
    await auth.cancel(first.id)
    await auth.cancel("unknown")
    expect(
      events.filter((event) => (event.payload as { completed?: boolean }).completed === true)
    ).toEqual([])
    expect(loginFailed).toHaveBeenCalledTimes(1)
    const gone = setup({ replies: { "account/loginCancel": new Error("muse exited") } })
    const flow = await gone.auth.begin(account(), "deviceCode", undefined)
    await gone.auth.cancel(flow.id)
    expect(gone.hosts[0]!.state.closed).toBe(true)
  })

  it("stores a Meta API key through Muse and checks it took", async () => {
    const { auth, hosts, setActive } = setup({ shared: "empty" })
    await expect(auth.begin(account(), "apiKey", "  ")).rejects.toThrow("API key is required")
    await expect(auth.begin(account(), "apiKey", undefined)).rejects.toThrow("API key is required")
    expect(hosts).toEqual([])
    await expect(auth.begin(account(), "apiKey", " sk-meta ")).resolves.toEqual({
      id: expect.any(String),
      accountId: "acct-1",
      kind: "complete"
    })
    expect(hosts[0]!.requests[1]!.params).toEqual({ type: "apiKey", apiKey: "sk-meta" })
    expect(hosts[0]!.state.closed).toBe(true)
    expect(setActive).toHaveBeenCalled()
    const rejected = setup({ signedIn: false, shared: "empty" })
    await expect(rejected.auth.begin(account(), "apiKey", "sk-bad")).rejects.toThrow(
      "Muse Code couldn't verify that API key."
    )
  })

  it("with account sync on, saves the sign-in to the shared vault instead of probing", async () => {
    const { auth, hosts, probe, captureLogin, saveApiKey, completed } = setup()
    await auth.begin(account(), "deviceCode", undefined)
    const done = completed()
    hosts[0]!.complete("granted")
    await expect(done).resolves.toMatchObject({ success: true })
    expect(captureLogin).toHaveBeenCalledWith("acct-1")
    expect(probe).not.toHaveBeenCalled()

    await expect(auth.begin(account(), "apiKey", " sk-meta ")).resolves.toMatchObject({
      kind: "complete"
    })
    expect(saveApiKey).toHaveBeenCalledWith("acct-1", "sk-meta")
    expect(hosts).toHaveLength(1)

    const unsaved = setup({ captureError: new Error("Sign-in could not be saved") })
    await unsaved.auth.begin(account(), "deviceCode", undefined)
    const failed = unsaved.completed()
    unsaved.hosts[0]!.complete("granted")
    await expect(failed).resolves.toMatchObject({ success: false })
    expect(unsaved.loginFailed).toHaveBeenCalledWith("acct-1")
  })

  it("closes the host when Muse can't start a sign-in", async () => {
    const refused = setup({ replies: { "account/loginStart": new Error("experimentalRequired") } })
    await expect(refused.auth.begin(account(), "deviceCode", undefined)).rejects.toThrow(
      "experimentalRequired"
    )
    expect(refused.hosts[0]!.state.closed).toBe(true)
    const stale = setup({ replies: { initialize: { serverInfo: { version: "1.0.0" } } } })
    await expect(stale.auth.begin(account(), "deviceCode", undefined)).rejects.toThrow(/too old/)
    expect(stale.hosts[0]!.state.closed).toBe(true)
  })

  it("gives up on a code nobody confirms", async () => {
    vi.useFakeTimers()
    try {
      const { auth, hosts, completed } = setup({ deadlineMs: 1000 })
      await auth.begin(account(), "deviceCode", undefined)
      const done = completed()
      await vi.advanceTimersByTimeAsync(1000)
      await expect(done).resolves.toMatchObject({ completed: true, success: false })
      expect(hosts[0]!.methods()).toContain("account/loginCancel")
      expect(hosts[0]!.state.closed).toBe(true)
      const gone = setup({
        deadlineMs: 1000,
        replies: { "account/loginCancel": new Error("muse exited") }
      })
      await gone.auth.begin(account(), "deviceCode", undefined)
      const lapsed = gone.completed()
      await vi.advanceTimersByTimeAsync(1000)
      await expect(lapsed).resolves.toMatchObject({ success: false })
    } finally {
      vi.useRealTimers()
    }
  })

  it("signs out through Muse", async () => {
    const { auth, hosts } = setup()
    await auth.logout(account())
    expect(hosts[0]!.methods()).toEqual(["initialize", "account/logout"])
    expect(hosts[0]!.state.closed).toBe(true)
  })
})
