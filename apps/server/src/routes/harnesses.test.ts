import type { Harness } from "@codevisor/api"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"

describe("harness routes", () => {
  it("exposes harness authentication and account management routes", async () => {
    const { services, agents } = await makeServices("server-a")
    const legacyServer = await startWithApp(services)
    runningServers.push(legacyServer)
    const unavailableRequests: ReadonlyArray<readonly [string, string]> = [
      ["GET", "/v1/harnesses/pi/providers"],
      ["POST", "/v1/harnesses/pi/providers/openai/login"],
      ["DELETE", "/v1/harnesses/pi/providers/openai"],
      ["POST", "/v1/harnesses/pi/auth-flows/pi-flow-1/answer"],
      ["GET", "/v1/harnesses/pi/auth-flows/pi-flow-1"],
      ["DELETE", "/v1/harnesses/pi/auth-flows/pi-flow-1"],
      ["POST", "/v1/harnesses/auth/refresh"],
      ["DELETE", "/v1/harnesses/codex/accounts/account-1/login/flow-1"],
      ["POST", "/v1/harnesses/codex/accounts/account-1/login"],
      ["POST", "/v1/harnesses/codex/accounts/account-1/auth/probe"],
      ["PATCH", "/v1/harnesses/codex/accounts/account-1"],
      ["GET", "/v1/harnesses/codex/accounts"],
      ["GET", "/v1/harnesses/opencode/accounts/account-1/providers"],
      ["POST", "/v1/harnesses/opencode/accounts/account-1/providers/openai/login"],
      ["DELETE", "/v1/harnesses/opencode/accounts/account-1/providers/openai"],
      ["GET", "/v1/harnesses/opencode/auth-flows/flow-open"],
      ["DELETE", "/v1/harnesses/opencode/auth-flows/flow-open"],
      ["POST", "/v1/harnesses/opencode/auth-flows/flow-open/answer"]
    ]
    for (const [method, path] of unavailableRequests) {
      expect(
        (
          await jsonRequest(legacyServer, path, {
            method,
            ...(method === "PATCH" || method === "POST" ? { body: JSON.stringify({}) } : {})
          })
        ).status
      ).toBe(501)
    }

    const account = {
      id: "account-1",
      harnessId: "codex",
      profileKind: "default" as const,
      label: "person@example.com",
      email: "person@example.com",
      authState: "authenticated" as const,
      isActive: true,
      canLogin: true,
      canLogout: true
    }
    const accountList = [account]
    const piProvider = { id: "openai", name: "OpenAI", methods: ["api_key" as const] }
    const piFlow = {
      id: "pi-flow-1",
      providerId: piProvider.id,
      state: "waiting" as const,
      prompt: {
        id: "api-key",
        type: "secret" as const,
        message: "Enter OpenAI API key",
        options: []
      }
    }
    let authState: "authenticated" | "unauthenticated" = "authenticated"
    let activeContextAvailable = true
    const auth: HarnessAuthManager = {
      decorateHarnesses: async (values) =>
        values.map((harness) => ({
          ...harness,
          desiredEnabled: harness.enabled,
          auth: {
            state: authState,
            activeAccountId: account.id,
            accounts: accountList,
            loginMethods: [{ id: "browser", name: "Browser", kind: "browser" }],
            supportsMultipleAccounts: true
          }
        })),
      refresh: vi.fn(async () => undefined),
      accounts: vi.fn(async () => accountList),
      createAccount: vi.fn(async () => account),
      renameAccount: vi.fn(async () => account),
      removeAccount: vi.fn(async () => undefined),
      activateAccount: vi.fn(async () => undefined),
      probeAccount: vi.fn(async () => account),
      beginLogin: vi.fn(async () => ({
        id: "flow-1",
        accountId: account.id,
        kind: "complete" as const
      })),
      cancelLogin: vi.fn(async () => undefined),
      logout: vi.fn(async () => ({ ...account, authState: "unauthenticated" as const })),
      accountContext: vi.fn(async () => ({ id: account.id, profileKind: "default" as const })),
      activeAccountContext: vi.fn(async () =>
        activeContextAvailable ? { id: account.id, profileKind: "default" as const } : undefined
      ),
      markAccountExpired: vi.fn(async () => undefined),
      piProviders: vi.fn(async () => [piProvider]),
      beginPiLogin: vi.fn(async () => piFlow),
      piLoginFlow: vi.fn(() => piFlow),
      answerPiLogin: vi.fn(async () => ({ ...piFlow, state: "complete" as const })),
      cancelPiLogin: vi.fn(() => undefined),
      logoutPiProvider: vi.fn(async () => undefined),
      openCodeProviders: vi.fn(async () => [
        {
          id: "openai",
          name: "OpenAI",
          methods: [{ id: "0", type: "oauth" as const, label: "ChatGPT", prompts: [] }],
          credentialType: "oauth" as const
        }
      ]),
      beginOpenCodeLogin: vi.fn(async () => ({
        id: "flow-open",
        accountId: account.id,
        providerId: "openai",
        state: "waiting" as const,
        authorization: {
          url: "https://example.test/login",
          method: "code" as const,
          instructions: "Sign in"
        }
      })),
      openCodeLoginFlow: vi.fn(() => ({
        id: "flow-open",
        accountId: account.id,
        providerId: "openai",
        state: "waiting" as const
      })),
      answerOpenCodeLogin: vi.fn(async () => ({
        id: "flow-open",
        accountId: account.id,
        providerId: "openai",
        state: "complete" as const
      })),
      cancelOpenCodeLogin: vi.fn(() => undefined),
      logoutOpenCodeProvider: vi.fn(async () => undefined),
      subscribe: () => () => undefined
    }
    const server = await startWithApp({ ...services, auth })
    runningServers.push(server)

    expect((await jsonRequest(server, "/v1/harnesses")).status).toBe(200)
    expect((await jsonRequest(server, "/v1/harnesses/pi/providers")).body).toEqual([piProvider])
    expect(
      await jsonRequest(server, "/v1/harnesses/pi/providers/openai/login", {
        method: "POST",
        body: JSON.stringify({ method: "api_key" })
      })
    ).toMatchObject({ status: 201, body: piFlow })
    expect(auth.beginPiLogin).toHaveBeenCalledWith("openai", "api_key")
    expect(
      await jsonRequest(server, "/v1/harnesses/pi/auth-flows/pi-flow-1/answer", {
        method: "POST",
        body: JSON.stringify({ value: "sk-test" })
      })
    ).toMatchObject({ status: 200, body: { state: "complete" } })
    expect(auth.answerPiLogin).toHaveBeenCalledWith("pi-flow-1", "sk-test")
    expect((await jsonRequest(server, "/v1/harnesses/pi/auth-flows/pi-flow-1")).body).toEqual(
      piFlow
    )
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/pi/auth-flows/pi-flow-1", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(auth.cancelPiLogin).toHaveBeenCalledWith("pi-flow-1")
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/pi/providers/openai", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(auth.logoutPiProvider).toHaveBeenCalledWith("openai")
    for (const [method, path] of [
      ["GET", "/v1/harnesses/pi/providers/openai/login"],
      ["GET", "/v1/harnesses/pi/providers/openai"],
      ["GET", "/v1/harnesses/pi/auth-flows/pi-flow-1/answer"],
      ["POST", "/v1/harnesses/pi/auth-flows/pi-flow-1"],
      ["POST", "/v1/harnesses/opencode/auth-flows/flow-open"]
    ] as const) {
      expect((await jsonRequest(server, path, { method })).status).toBe(404)
    }
    expect(
      (await jsonRequest(server, "/v1/harnesses/auth/refresh", { method: "POST" })).status
    ).toBe(200)
    const targetedRefresh = await jsonRequest(
      server,
      "/v1/harnesses/auth/refresh?harnessId=codex",
      { method: "POST" }
    )
    expect(targetedRefresh).toMatchObject({
      status: 200,
      body: [{ id: "codex" }]
    })
    expect(auth.refresh).toHaveBeenLastCalledWith("codex")
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1/unknown", {
          method: "POST",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "GET"
        })
      ).status
    ).toBe(404)
    expect((await jsonRequest(server, "/v1/harnesses/codex/accounts")).body).toEqual(accountList)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts", {
          method: "POST",
          body: JSON.stringify({ label: "Work" })
        })
      ).status
    ).toBe(201)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts", {
          method: "PUT",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "PATCH",
          body: JSON.stringify({ label: "Renamed" })
        })
      ).status
    ).toBe(200)
    authState = "unauthenticated"
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(409)
    authState = "authenticated"
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1/auth/probe", {
          method: "POST"
        })
      ).status
    ).toBe(200)
    for (const action of ["activate", "login", "logout"]) {
      expect(
        (
          await jsonRequest(server, `/v1/harnesses/codex/accounts/account-1/${action}`, {
            method: "POST",
            body: JSON.stringify(
              action === "login" ? { methodId: "apiKey", apiKey: "sk-test-secret" } : {}
            )
          })
        ).status
      ).toBe(action === "login" ? 201 : 200)
    }
    expect(auth.beginLogin).toHaveBeenCalledWith("account-1", "apiKey", "sk-test-secret")
    expect(
      (await jsonRequest(server, "/v1/harnesses/opencode/accounts/account-1/providers")).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(
          server,
          "/v1/harnesses/opencode/accounts/account-1/providers/openai/login",
          {
            method: "POST",
            body: JSON.stringify({
              methodId: "0",
              inputs: { plan: "plus" }
            })
          }
        )
      ).status
    ).toBe(201)
    expect(auth.beginOpenCodeLogin).toHaveBeenCalledWith(
      "account-1",
      "openai",
      "0",
      { plan: "plus" },
      undefined
    )
    expect((await jsonRequest(server, "/v1/harnesses/opencode/auth-flows/flow-open")).status).toBe(
      200
    )
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/opencode/auth-flows/flow-open/answer", {
          method: "POST",
          body: JSON.stringify({ code: "authorization-code" })
        })
      ).status
    ).toBe(200)
    expect(auth.answerOpenCodeLogin).toHaveBeenCalledWith("flow-open", "authorization-code")
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/opencode/accounts/account-1/providers/openai", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/opencode/auth-flows/flow-open", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1/login/flow-1", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex/accounts/account-1", {
          method: "DELETE"
        })
      ).status
    ).toBe(204)

    const projectFolder = mkdtempSync(join(tmpdir(), "codevisor-auth-project-"))
    tempDirs.push(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        method: "POST",
        body: JSON.stringify({ folderPath: projectFolder })
      })
    ).body as { id: string }
    await run(
      services.db.saveHarnessAccount({
        id: account.id,
        harnessId: account.harnessId,
        profileKind: account.profileKind,
        label: account.label,
        email: account.email,
        authState: account.authState,
        canLogin: account.canLogin,
        canLogout: account.canLogout
      })
    )
    const createdResponse = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({ projectId: project.id, harnessId: "codex" })
    })
    expect(createdResponse.status).toBe(201)
    const created = createdResponse.body as {
      id: string
      agentSessionId: string
      harnessAccountId: string
    }
    expect(created.harnessAccountId).toBe(account.id)
    await agents.emit(created.agentSessionId, {
      kind: "session.authRequired",
      subjectId: created.agentSessionId,
      payload: { detail: "Please sign in again" }
    })
    await agents.emit(created.agentSessionId, {
      kind: "session.authRequired",
      subjectId: created.agentSessionId,
      payload: null
    })
    await waitFor(() => vi.mocked(auth.markAccountExpired).mock.calls.length === 2)
    await jsonRequest(server, `/v1/sessions/${created.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "token expired" })
    })
    await waitFor(() => vi.mocked(auth.markAccountExpired).mock.calls.length === 3)
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(created.id))).some(
        (event) => event.kind === "session.error"
      )
    )

    const explicitAccountSession = await jsonRequest(server, "/v1/sessions", {
      method: "POST",
      body: JSON.stringify({
        projectId: project.id,
        harnessId: "codex",
        harnessAccountId: account.id,
        deferAgentSession: true
      })
    })
    expect(explicitAccountSession.status).toBe(201)

    activeContextAvailable = false
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          method: "POST",
          body: JSON.stringify({ projectId: project.id, harnessId: "codex" })
        })
      ).status
    ).toBe(409)

    activeContextAvailable = true
    const legacy = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: ""
      })
    )
    await jsonRequest(server, `/v1/sessions/${legacy.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "hello" })
    })
    await waitFor(
      async () =>
        (await run(services.db.getSessionSummary(legacy.id))).harnessAccountId === account.id
    )
    await waitFor(async () => (await run(services.db.listPromptQueue(legacy.id))).length === 0)
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(legacy.id))).some(
        (event) =>
          event.kind === "session.updated" &&
          typeof event.payload === "object" &&
          event.payload !== null &&
          "turnState" in event.payload &&
          event.payload.turnState === "ended"
      )
    )

    activeContextAvailable = false
    const blocked = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex", agentSessionId: "" })
    )
    await jsonRequest(server, `/v1/sessions/${blocked.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "blocked" })
    })
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(blocked.id))).some(
        (event) => event.kind === "session.error"
      )
    )
  })

  describe("custom harness routes", () => {
    const makeStore = () => {
      const replaced: Array<ReadonlyArray<unknown>> = []
      const tested: Array<unknown> = []
      return {
        replaced,
        tested,
        store: {
          list: async () => [{ command: "my-agent", id: "mine", name: "Mine" }],
          replace: async (specs: ReadonlyArray<unknown>) => {
            replaced.push(specs)
          },
          test: async (spec: unknown) => {
            tested.push(spec)
            return { agentName: "Mine", ok: true, protocolVersion: 1 }
          }
        }
      }
    }

    it("lists custom harnesses", async () => {
      const { services } = await makeServices("server-a")
      const { store } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom")
      expect(response.status).toBe(200)
      expect(response.body).toEqual({
        harnesses: [{ command: "my-agent", id: "mine", name: "Mine" }]
      })
    })

    it("replaces the list and returns the refreshed harness catalog", async () => {
      const { services } = await makeServices("server-a")
      const { replaced, store } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom", {
        body: JSON.stringify({
          harnesses: [{ args: ["acp"], command: "my-agent", id: "mine", name: "Mine" }]
        }),
        method: "PUT"
      })
      expect(response.status).toBe(200)
      // Blocking rescan semantics: the fresh discovery list comes back.
      expect(response.body).toMatchObject([{ id: "codex" }])
      expect(replaced).toEqual([[{ args: ["acp"], command: "my-agent", id: "mine", name: "Mine" }]])
    })

    it("rejects invalid replacement lists without persisting", async () => {
      const { services } = await makeServices("server-a")
      const { replaced, store } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom", {
        body: JSON.stringify({
          harnesses: [{ command: "fake-codex", id: "codex", name: "Fake Codex" }]
        }),
        method: "PUT"
      })
      expect(response.status).toBe(400)
      expect(replaced).toEqual([])
    })

    it("runs the ACP handshake test for a spec", async () => {
      const { services } = await makeServices("server-a")
      const { store, tested } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom/test", {
        body: JSON.stringify({ command: "my-agent", id: "mine", name: "Mine" }),
        method: "POST"
      })
      expect(response.status).toBe(200)
      expect(response.body).toEqual({ agentName: "Mine", ok: true, protocolVersion: 1 })
      expect(tested).toHaveLength(1)
    })

    it("rejects an invalid test spec", async () => {
      const { services } = await makeServices("server-a")
      const { store, tested } = makeStore()
      const server = await startWithApp({ ...services, customHarnesses: store })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom/test", {
        body: JSON.stringify({ command: "", id: "bad", name: "Bad" }),
        method: "POST"
      })
      expect(response.status).toBe(400)
      expect(tested).toEqual([])
    })

    it("returns 501 when the host has no custom-harness store", async () => {
      const { services } = await makeServices("server-a")
      const server = await startWithApp(services)
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/custom")
      expect(response.status).toBe(501)
    })
  })

  describe("harness update checks", () => {
    it("forces a check and returns the decorated harness list", async () => {
      const { services } = await makeServices("server-a")
      const checks: Array<boolean> = []
      const lifecycle = {
        beginBundledAppUpdate: async () => {},
        beginInstall: async () => ({ terminalId: "unused" }),
        beginUpdate: async () => ({ queued: false }),
        bundledAppInfo: async () => undefined,
        cancelPendingUpdate: async () => {},
        checkForUpdates: async (force?: boolean) => {
          checks.push(force === true)
          return []
        },
        decorateHarnesses: async (list: ReadonlyArray<Harness>) =>
          list.map((harness) => ({
            ...harness,
            updateInfo: { latestVersion: "9.9.9", updateAvailable: true }
          })),
        forcePendingUpdate: async () => {},
        installMethods: async () => [],
        isGated: () => false,
        notifyTurnEnded: () => {},
        notifyTurnStarted: () => {},
        onGateReleased: () => () => {},
        reconcileOnStartup: async () => {},
        startPeriodicChecks: () => () => {},
        subscribe: () => () => {}
      }
      const server = await startWithApp({ ...services, lifecycle })
      runningServers.push(server)

      const response = await jsonRequest(server, "/v1/harnesses/check-updates", { method: "POST" })
      expect(response.status).toBe(200)
      expect(checks).toEqual([true])
      expect(response.body).toMatchObject([
        { id: "codex", updateInfo: { latestVersion: "9.9.9", updateAvailable: true } }
      ])

      // Lifecycle decoration is opt-in: the plain list (the composer picker's
      // path) skips it, ?include=lifecycle carries it.
      const plain = await jsonRequest(server, "/v1/harnesses")
      expect((plain.body as Array<{ updateInfo?: unknown }>)[0]?.updateInfo).toBeUndefined()
      const decorated = await jsonRequest(server, "/v1/harnesses?include=lifecycle")
      expect(decorated.body).toMatchObject([{ id: "codex", updateInfo: { updateAvailable: true } }])
    })

    it("drives install, update, pending, and bundled-app routes", async () => {
      const { services } = await makeServices("server-a")
      const calls: Array<string> = []
      const lifecycle = {
        beginBundledAppUpdate: async (id: string) => {
          if (id !== "codex") throw new Error("no bundled desktop app")
          calls.push(`bundled-update ${id}`)
        },
        beginInstall: async (id: string, methodId?: string) => {
          // Non-Error throw exercises the conflict mapping's String branch.
          // oxlint-disable-next-line no-throw-literal
          if (methodId === "carrier-pigeon") throw "no runnable install method"
          calls.push(`install ${id} ${methodId ?? "auto"}`)
          return { terminalId: "terminal-9" }
        },
        beginUpdate: async (id: string) => {
          if (id === "kimi") throw new Error("kimi has no update source")
          calls.push(`update ${id}`)
          return { lifecycle: { phase: "pendingUpdate" as const }, queued: true }
        },
        bundledAppInfo: async (id: string) =>
          id === "codex"
            ? {
                appName: "ChatGPT",
                bundlePath: "/Applications/ChatGPT.app",
                installedVersion: "1.0",
                latestVersion: "2.0",
                updateAvailable: true
              }
            : undefined,
        cancelPendingUpdate: async (id: string) => {
          if (id !== "codex") throw new Error("No pending update")
          calls.push(`cancel ${id}`)
        },
        checkForUpdates: async () => [],
        decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
        forcePendingUpdate: async (id: string) => {
          if (id !== "codex") throw new Error("No pending update")
          calls.push(`force ${id}`)
        },
        installMethods: async () => [],
        isGated: () => false,
        notifyTurnEnded: () => {},
        notifyTurnStarted: () => {},
        onGateReleased: () => () => {},
        reconcileOnStartup: async () => {},
        startPeriodicChecks: () => () => {},
        subscribe: () => () => {}
      }
      const server = await startWithApp({ ...services, lifecycle })
      runningServers.push(server)

      const install = await jsonRequest(server, "/v1/harnesses/codex/install", {
        body: JSON.stringify({ methodId: "brew" }),
        method: "POST"
      })
      expect(install.status).toBe(202)
      expect(install.body).toMatchObject({ accepted: true, terminalId: "terminal-9" })
      // Method omitted → the server resolves the recommended one.
      const autoInstall = await jsonRequest(server, "/v1/harnesses/codex/install", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(autoInstall.status).toBe(202)
      const badInstall = await jsonRequest(server, "/v1/harnesses/codex/install", {
        body: JSON.stringify({ methodId: "carrier-pigeon" }),
        method: "POST"
      })
      expect(badInstall.status).toBe(409)
      expect(badInstall.body).toMatchObject({ error: "no runnable install method" })

      // Custom-harness collection accepts only GET/PUT — other verbs fall
      // through to later routes rather than mutating the store.
      const wrongMethod = await jsonRequest(server, "/v1/harnesses/custom", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(wrongMethod.status).toBeGreaterThanOrEqual(400)

      const update = await jsonRequest(server, "/v1/harnesses/codex/update", { method: "POST" })
      expect(update.status).toBe(202)
      expect(update.body).toMatchObject({
        accepted: true,
        lifecycle: { phase: "pendingUpdate" },
        queued: true
      })
      const badUpdate = await jsonRequest(server, "/v1/harnesses/kimi/update", { method: "POST" })
      expect(badUpdate.status).toBe(409)

      const pendingApply = await jsonRequest(server, "/v1/harnesses/codex/update/pending/apply", {
        method: "POST"
      })
      expect(pendingApply.status).toBe(202)
      const badApply = await jsonRequest(server, "/v1/harnesses/gemini/update/pending/apply", {
        method: "POST"
      })
      expect(badApply.status).toBe(409)
      const pendingCancel = await jsonRequest(server, "/v1/harnesses/codex/update/pending", {
        method: "DELETE"
      })
      expect(pendingCancel.status).toBe(204)
      const badCancel = await jsonRequest(server, "/v1/harnesses/gemini/update/pending", {
        method: "DELETE"
      })
      expect(badCancel.status).toBe(409)

      const bundled = await jsonRequest(server, "/v1/harnesses/codex/bundled-app")
      expect(bundled.status).toBe(200)
      expect(bundled.body).toMatchObject({ appName: "ChatGPT", updateAvailable: true })
      const noBundle = await jsonRequest(server, "/v1/harnesses/gemini/bundled-app")
      expect(noBundle.status).toBe(404)
      const bundledUpdate = await jsonRequest(server, "/v1/harnesses/codex/bundled-app/update", {
        method: "POST"
      })
      expect(bundledUpdate.status).toBe(202)
      const badBundled = await jsonRequest(server, "/v1/harnesses/gemini/bundled-app/update", {
        method: "POST"
      })
      expect(badBundled.status).toBe(409)

      expect(calls).toEqual([
        "install codex brew",
        "install codex auto",
        "update codex",
        "force codex",
        "cancel codex",
        "bundled-update codex"
      ])
    })

    it("returns 501 without a lifecycle manager", async () => {
      const { services } = await makeServices("server-a")
      const server = await startWithApp(services)
      runningServers.push(server)

      for (const [path, method] of [
        ["/v1/harnesses/check-updates", "POST"],
        ["/v1/harnesses/codex/install", "POST"],
        ["/v1/harnesses/codex/update", "POST"],
        ["/v1/harnesses/codex/update/pending/apply", "POST"],
        ["/v1/harnesses/codex/update/pending", "DELETE"],
        ["/v1/harnesses/codex/bundled-app", "GET"],
        ["/v1/harnesses/codex/bundled-app/update", "POST"],
        ["/v1/harnesses/custom/test", "POST"]
      ] as const) {
        const response = await jsonRequest(server, path, { method })
        expect(response.status, `${method} ${path}`).toBe(501)
      }
    })

    it("holds prompts while the harness update gate is closed and dispatches on release", async () => {
      const { agents, services } = await makeServices("server-a")
      const gated = new Set<string>()
      const turns: Array<string> = []
      let releaseListener: ((harnessId: string) => void) | undefined
      const lifecycle = {
        beginBundledAppUpdate: async () => {},
        beginInstall: async () => ({ terminalId: "unused" }),
        beginUpdate: async () => ({ queued: false }),
        bundledAppInfo: async () => undefined,
        cancelPendingUpdate: async () => {},
        checkForUpdates: async () => [],
        decorateHarnesses: async (list: ReadonlyArray<Harness>) => list,
        forcePendingUpdate: async () => {},
        installMethods: async () => [],
        isGated: (harnessId: string) => gated.has(harnessId),
        notifyTurnEnded: (harnessId: string) => turns.push(`end ${harnessId}`),
        notifyTurnStarted: (harnessId: string) => turns.push(`start ${harnessId}`),
        onGateReleased: (listener: (harnessId: string) => void) => {
          releaseListener = listener
          return () => {}
        },
        reconcileOnStartup: async () => {},
        startPeriodicChecks: () => () => {},
        subscribe: () => () => {}
      }
      const server = await startWithApp({ ...services, lifecycle })
      runningServers.push(server)

      const folder = join(mkdtempSync(join(tmpdir(), "codevisor-gate-")), "repo")
      mkdirSync(folder, { recursive: true })
      const project = (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath: folder }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const session = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ harnessId: "codex", projectId: project.id, title: "Gated" }),
          method: "POST"
        })
      ).body as { readonly id: string }

      // Gate closed: the prompt is accepted (202, durable) but never reaches
      // the provider.
      gated.add("codex")
      const accepted = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "held prompt" }),
        method: "POST"
      })
      expect(accepted.status).toBe(202)
      // A second send while held re-queues without a duplicate hold marker.
      const second = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "also held" }),
        method: "POST"
      })
      expect(second.status).toBe(202)
      await new Promise((resolve) => setTimeout(resolve, 150))
      expect(agents.prompts).toHaveLength(0)
      // The transcript-facing hold marker was persisted for replay.
      const heldEvents = await run(services.db.listSubjectEvents(session.id))
      expect(
        heldEvents.some(
          (event) =>
            event.kind === "session.updateGate.updated" &&
            (event.payload as { state?: string }).state === "waiting"
        )
      ).toBe(true)

      // A release for a different harness leaves this session held.
      releaseListener?.("gemini")
      await new Promise((resolve) => setTimeout(resolve, 100))
      expect(agents.prompts).toHaveLength(0)

      // Gate releases → the held prompts dispatch and turn accounting ran.
      gated.delete("codex")
      releaseListener?.("codex")
      await waitFor(() => agents.prompts.length === 2)
      expect(agents.prompts[0]?.[1]).toBe("held prompt")
      await waitFor(() => turns.includes("end codex"))
      expect(turns[0]).toBe("start codex")
    })
  })

  it("capabilities lists sign-in-pending harnesses without inspecting them", async () => {
    const { services, agents } = await makeServices("server-a")
    const auth = {
      // The fixture catalog holds one harness; the decorator plays the
      // auth manager's role and contributes a second, sign-in-pending one.
      decorateHarnesses: (list: ReadonlyArray<Harness>) =>
        Promise.resolve([
          ...list.map((harness) => ({
            ...harness,
            desiredEnabled: true,
            enabled: true,
            readiness: { state: "ready" },
            auth: { state: "authenticated" }
          })),
          ...list.map((harness) => ({
            ...harness,
            id: "claude-code",
            name: "Claude Code",
            desiredEnabled: true,
            enabled: false,
            readiness: { state: "ready" },
            auth: { state: "unauthenticated" }
          }))
        ]),
      activeAccountContext: () => Promise.resolve(undefined),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const server = await startWithApp({ ...services, auth })

    const cwd = mkdtempSync(join(tmpdir(), "codevisor-cap-"))
    tempDirs.push(cwd)
    const body = (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(cwd)}`))
      .body as {
      harnesses: Array<{
        harness: { id: string; enabled: boolean }
        configOptions: ReadonlyArray<unknown>
      }>
    }
    // The signed-in harness is inspected as before…
    expect(body.harnesses.some((entry) => entry.harness.id === "codex")).toBe(true)
    // …and the sign-in-pending ones ride along with no options and, above
    // all, no inspection (inspection spawns the harness CLI).
    const pending = body.harnesses.filter((entry) => !entry.harness.enabled)
    expect(pending.length).toBeGreaterThan(0)
    expect(pending.every((entry) => entry.configOptions.length === 0)).toBe(true)
    expect(agents.inspections.map(([id]) => id)).toEqual(["codex"])
  })
})
