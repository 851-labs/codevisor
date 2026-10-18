import { mkdtemp, rm, symlink } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import { accountInspection, cancelMuseLogin, logoutMuse, startMuseLogin } from "./auth.js"
import { MuseExitedError } from "./client.js"
import { makeMuseProvider } from "./provider.js"
import { definition, environment, FakeMuseClient, run, session, setup } from "./test-support.js"
import { museUsageLimits, observeMuseUsageLimits } from "./usage.js"

describe("Muse provider", () => {
  it("is ready when muse is installed, including the installer's own directory", () => {
    const { provider } = setup()
    expect(provider.readiness(definition)).toEqual({ state: "ready" })
    expect(provider.readiness({ ...definition, detectBinaries: ["nope"] })).toEqual({
      state: "unavailable",
      detail: "CLI not found on PATH"
    })
    expect(
      provider.readiness({ ...definition, detectBinaries: ["nope"], fallbackPaths: ["muse"] })
    ).toEqual({ state: "ready" })
  })

  it("starts each chat on its own full-access host with the account's environment", async () => {
    const { provider, spawned, emit, client } = setup()
    const created = await run(
      provider.createSession(definition, "/repo", emit, {
        id: "a",
        profileKind: "default",
        env: { MUSE_TOKEN: "x" },
        unsetEnv: ["PATH"]
      })
    )
    expect(spawned).toEqual([
      {
        command: "/bin/muse",
        args: ["--trust-workspace", "--disable-sandbox"],
        cwd: "/repo",
        env: { HOME: "/home/me", MUSE_TOKEN: "x" }
      }
    ])
    expect(client.notified).toEqual(["initialized"])
    expect(created.metadata).toMatchObject({
      sessionId: "s-1",
      configOptions: [{ id: "model" }, { id: "thought_level" }],
      skills: { skills: [] }
    })

    const { handle } = created
    await expect(run(handle.setMode("plan"))).rejects.toThrow()
    expect(await run(handle.setConfigOption("thought_level", "low"))).toEqual(
      expect.arrayContaining([expect.objectContaining({ currentValue: "low" })])
    )
    const sent = client.nextRequest("turn/start")
    const prompted = run(handle.prompt("hi"))
    await sent
    expect(await run(handle.cancel)).toEqual({ runtimeState: "reusable" })
    client.emit("turn/completed", {
      turnId: client.sent("turn/start")[0]!.commandId,
      terminal: "cancelled"
    })
    await expect(prompted).resolves.toEqual({ stopReason: "cancelled" })
    await expect(run(handle.answerQuestion!("nope", { outcome: "cancelled" }))).rejects.toThrow()
    await run(handle.close)
    expect(client.closed).toBe(true)
  })

  it("gives Muse the real path of a symlinked workspace", async () => {
    const directory = await mkdtemp(join(tmpdir(), "muse-workspace-"))
    onTestFinished(() => rm(directory, { recursive: true, force: true }))
    const linked = join(directory, "linked")
    await symlink(directory, linked)
    const { provider, spawned, emit, client } = setup()
    await run(provider.createSession(definition, linked, emit))
    const real = spawned[0]!.cwd
    expect(real).not.toBe(linked)
    expect(real.endsWith(directory.split("/").at(-1)!)).toBe(true)
    expect(client.sent("session/start")[0]).toMatchObject({ workspaceRoot: real })
  })

  it("resumes a Muse session by id, with Codevisor's tools", async () => {
    const { provider, emit, client } = setup()
    const gateway = { name: "codevisor", url: "http://127.0.0.1:1/mcp", bearerToken: "t" }
    const loaded = await run(
      provider.loadSession(definition, "s-1", "/repo", emit, undefined, gateway)
    )
    expect(loaded.sessionId).toBe("s-1")
    expect(client.sent("session/resume")[0]).toMatchObject({
      sessionId: "s-1",
      excludeItems: true,
      config: { mcpServers: { codevisor: { url: "http://127.0.0.1:1/mcp" } } }
    })
    expect(makeMuseProvider(environment).readiness(definition)).toEqual({ state: "ready" })
  })

  it("closes the host when a chat can't start", async () => {
    const { provider, emit, client } = setup()
    client.replies.initialize = { serverInfo: { version: "1.0.0" } }
    await expect(run(provider.createSession(definition, "/repo", emit))).rejects.toThrow(/too old/)
    expect(client.closed).toBe(true)
    const skillless = setup()
    skillless.client.replies["skill/list"] = new Error("no skills")
    const created = await run(skillless.provider.createSession(definition, "/repo", skillless.emit))
    expect(created.metadata).not.toHaveProperty("skills")
    const missing = setup()
    await expect(
      run(
        missing.provider.createSession(
          { ...definition, detectBinaries: ["nope"] },
          "/repo",
          missing.emit
        )
      )
    ).rejects.toThrow("muse not found on PATH")
  })

  it("lists root sessions across pages from a host that logs nothing", async () => {
    const { provider, spawned, client } = setup()
    client.replies["session/list"] = (params: Record<string, unknown>) =>
      params.cursor === undefined
        ? {
            sessions: [
              session({ name: "Named" }),
              session({ sessionId: "s-2", title: "Titled", kind: "root" }),
              session({ sessionId: "child", kind: "subagent" }),
              session({ sessionId: "nowhere", workspaceRoot: null })
            ],
            nextCursor: "p2"
          }
        : {
            sessions: [
              session({ sessionId: "s-3", firstUserPrompt: "Fix it" }),
              session({ sessionId: "s-4" })
            ]
          }
    const sessions = await provider.listAgentSessions!(definition)
    expect(sessions).toEqual([
      { sessionId: "s-1", cwd: "/repo", updatedAt: "2026-10-13T00:00:00Z", title: "Named" },
      { sessionId: "s-2", cwd: "/repo", updatedAt: "2026-10-13T00:00:00Z", title: "Titled" },
      { sessionId: "s-3", cwd: "/repo", updatedAt: "2026-10-13T00:00:00Z", title: "Fix it" },
      { sessionId: "s-4", cwd: "/repo", updatedAt: "2026-10-13T00:00:00Z" }
    ])
    expect(spawned[0]).toMatchObject({ args: ["--no-session-log"], cwd: "/home/me" })
    expect(client.closed).toBe(true)

    client.replies["session/list"] = { sessions: "bad", nextCursor: "more" }
    await provider.listAgentSessions!(definition)
    expect(client.sent("session/list")).toHaveLength(2 + 5)
  })

  it("reads Muse's subscription windows once it has seen them", async () => {
    const { provider, client } = setup()
    expect(await run(provider.readUsageLimits!(definition, "/repo"))).toMatchObject({
      harnessId: "muse-code",
      state: "unavailable",
      windows: []
    })
    client.replies["usage/read"] = {
      window: { usedPercent: 12, windowDurationMins: 300, resetsAtMs: 1791924961000 },
      weekly: { usedPercent: 140, resetsAtMs: 1792368000000 },
      tier: "27681631238169137"
    }
    expect((await run(provider.readUsageLimits!(definition, "/repo"))).windows).toEqual([
      {
        id: "window",
        label: "5-hour limit",
        usedPercent: 12,
        durationMinutes: 300,
        resetsAt: "2026-10-13T20:56:01.000Z"
      },
      {
        id: "weekly",
        label: "Weekly limit",
        usedPercent: 100,
        resetsAt: "2026-10-19T00:00:00.000Z"
      }
    ])
    expect(museUsageLimits({ window: { usedPercent: 1, windowDurationMins: 60 } }).windows).toEqual(
      [{ id: "window", label: "Session limit", usedPercent: 1, durationMinutes: 60 }]
    )
  })

  it("gives up on a short-lived host that never answers", async () => {
    vi.useFakeTimers()
    try {
      const silent = new FakeMuseClient()
      silent.replies.initialize = new Promise(() => undefined)
      const { provider } = setup({ hostDeadlineMs: 1000 }, silent)
      const probe = run(provider.probeAuth!(definition))
      await vi.advanceTimersByTimeAsync(1000)
      await expect(probe).resolves.toMatchObject({
        state: "error",
        detail: "Muse Code didn't respond in time."
      })
      expect(silent.closed).toBe(true)
    } finally {
      vi.useRealTimers()
    }
  })

  it("probes sign-in through Muse's account state", async () => {
    const { provider, client } = setup()
    expect(await run(provider.probeAuth!(definition))).toEqual({
      state: "authenticated",
      methods: [],
      canLogout: true,
      label: "me@example.com"
    })
    client.replies["account/read"] = new MuseExitedError("muse exited: keychain locked")
    expect(await run(provider.probeAuth!(definition))).toMatchObject({
      state: "error",
      detail: "Muse Code couldn’t start: muse exited: keychain locked"
    })
    client.replies["account/read"] = new Error("experimentalRequired")
    expect(await run(provider.probeAuth!(definition))).toMatchObject({
      state: "error",
      detail: "experimentalRequired"
    })
    client.replies["account/read"] = new Error("")
    expect(await run(provider.probeAuth!(definition))).toMatchObject({
      detail: "Couldn't check Muse Code's sign-in."
    })
    const old = new FakeMuseClient()
    old.replies.initialize = new Error("handshake failed")
    const stale = setup({}, old)
    expect(await run(stale.provider.probeAuth!(definition))).toMatchObject({
      state: "error",
      detail: "handshake failed"
    })
    expect(old.closed).toBe(true)
  })
})

describe("Muse sign-in", () => {
  it("reads every credential lane", () => {
    expect(accountInspection({ state: "envKey", credentialRequired: true })).toEqual({
      state: "authenticated",
      methods: [],
      canLogout: false
    })
    expect(
      accountInspection({ state: "apiKey", credentialRequired: true, label: "Key ••42" })
    ).toMatchObject({ canLogout: true, label: "Key ••42" })
    expect(accountInspection({ state: "loggedOut", credentialRequired: false })).toEqual({
      state: "notRequired",
      methods: [],
      canLogout: false
    })
    expect(accountInspection({ state: "loggedOut", credentialRequired: true })).toMatchObject({
      state: "unauthenticated",
      detail: expect.stringContaining("Meta account")
    })
  })

  it("defaults an account Muse describes only partly", async () => {
    const { provider, client } = setup()
    client.replies["account/read"] = {}
    expect(await run(provider.probeAuth!(definition))).toMatchObject({ state: "unauthenticated" })
    client.replies["account/read"] = { state: "loggedOut", credentialRequired: false }
    expect(await run(provider.probeAuth!(definition))).toMatchObject({ state: "notRequired" })
  })

  it("runs the device-code flow until Muse reports how it ended", async () => {
    const client = new FakeMuseClient()
    const login = await startMuseLogin(client, { type: "deviceCode" })
    expect(client.sent("account/loginStart")).toEqual([{ type: "deviceCode" }])
    expect(login).toMatchObject({ verificationUrl: "https://meta.ai/device", userCode: "ABCD" })
    client.emit("account/changed", { state: "accountLogin" })
    client.emit("account/loginCompleted", { outcome: "granted" })
    await expect(login.completed).resolves.toEqual({ outcome: "granted" })

    const denied = await startMuseLogin(client, { type: "deviceCode" })
    client.emit("account/loginCompleted", { outcome: "expired", message: "The code expired." })
    await expect(denied.completed).resolves.toEqual({
      outcome: "expired",
      message: "The code expired."
    })

    client.replies["account/loginStart"] = {}
    const odd = await startMuseLogin(client, { type: "deviceCode" })
    expect(odd).not.toHaveProperty("verificationUrl")
    client.emit("account/loginCompleted", {})
    await expect(odd.completed).resolves.toEqual({ outcome: "failed" })

    const crashed = await startMuseLogin(client, { type: "deviceCode" })
    client.crash(new Error("muse exited"))
    await expect(crashed.completed).resolves.toEqual({ outcome: "failed", message: "muse exited" })
  })

  it("stores an API key synchronously, and cancels or signs out", async () => {
    const client = new FakeMuseClient()
    const login = await startMuseLogin(client, { type: "apiKey", apiKey: "sk-1" })
    expect(client.sent("account/loginStart")).toEqual([{ type: "apiKey", apiKey: "sk-1" }])
    await expect(login.completed).resolves.toEqual({ outcome: "granted" })
    await cancelMuseLogin(client)
    await logoutMuse(client)
    expect(client.requests.map((entry) => entry.method)).toEqual([
      "account/loginStart",
      "account/loginCancel",
      "account/logout"
    ])
  })

  it("runs account requests on a host started in the user's home", async () => {
    const { provider, spawned } = setup()
    await run(provider.probeAuth!(definition, { id: "a", profileKind: "default", env: { A: "1" } }))
    expect(spawned[0]).toEqual({
      command: "/bin/muse",
      args: ["--no-session-log"],
      cwd: environment.env.HOME,
      env: { ...environment.env, A: "1" }
    })
    const homeless = setup()
    const original = environment.env.HOME
    delete (environment.env as Record<string, string | undefined>).HOME
    try {
      await run(homeless.provider.probeAuth!(definition))
      expect(homeless.spawned[0]!.cwd).toBe(process.cwd())
    } finally {
      environment.env.HOME = original
    }
  })

  it("stays quiet when Muse has no plan usage to report", async () => {
    const emitted: Array<unknown> = []
    const emit = async (event: unknown) => void emitted.push(event)

    await observeMuseUsageLimits({ request: async () => ({}) }, "s-1", emit)
    await observeMuseUsageLimits(
      { request: () => Promise.reject(new Error("not ready")) },
      "s-1",
      emit
    )

    expect(emitted).toEqual([])
  })
})
