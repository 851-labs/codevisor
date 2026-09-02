import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"
import { makeAuthFixture } from "./harness-auth-test-support.js"

describe("harness routes", () => {
  it("returns 501 for authentication routes without an auth service", async () => {
    const { services } = await makeServices("server-a")
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
  })

  it("drives Pi, OpenCode, and account routes through the auth service", async () => {
    const { services } = await makeServices("server-a")
    const { accountList, auth, piFlow, piProvider, state } = makeAuthFixture()
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
    state.authState = "unauthenticated"
    expect(
      await jsonRequest(server, "/v1/harnesses/codex", {
        method: "PATCH",
        body: JSON.stringify({ enabled: false })
      })
    ).toMatchObject({
      status: 200,
      body: { id: "codex", enabled: false, desiredEnabled: false }
    })
    expect(
      await jsonRequest(server, "/v1/harnesses/codex", {
        method: "PATCH",
        body: JSON.stringify({ enabled: true })
      })
    ).toMatchObject({
      status: 200,
      body: {
        id: "codex",
        enabled: false,
        desiredEnabled: true,
        auth: { state: "unauthenticated" }
      }
    })
    state.authState = "authenticated"
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
  })

  it("binds sessions to harness accounts and reports expired sign-ins", async () => {
    const { services, agents } = await makeServices("server-a")
    const { account, auth, state } = makeAuthFixture()
    const server = await startWithApp({ ...services, auth })
    runningServers.push(server)
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

    state.activeContextAvailable = false
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          method: "POST",
          body: JSON.stringify({ projectId: project.id, harnessId: "codex" })
        })
      ).status
    ).toBe(409)

    state.activeContextAvailable = true
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

    state.activeContextAvailable = false
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
})
