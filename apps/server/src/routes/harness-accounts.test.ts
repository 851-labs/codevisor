import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { Harness } from "@codevisor/api"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { describe, expect, it, vi } from "vitest"

import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  waitFor,
  listSubjectEvents
} from "../test-support.js"

describe("harness account routes", () => {
  it("rebinds a session pinned to a dead account when a working account is active", async () => {
    const { services } = await makeServices("server-a")
    const baseAccount = {
      harnessId: "codex",
      profileKind: "managed" as const,
      canLogin: true,
      canLogout: true
    }
    for (const [id, authState] of [
      ["dead-account", "expired"],
      ["flaky-account", "expired"],
      ["active-account", "authenticated"]
    ] as const) {
      await run(
        services.db.saveHarnessAccount({
          ...baseAccount,
          id,
          profileKey: id,
          label: id,
          authState
        })
      )
    }
    let activeContext: { id: string; profileKind: "default" } | undefined = {
      id: "active-account",
      profileKind: "default"
    }
    const auth = {
      accountContext: vi.fn(async (id: string) => {
        if (id === "active-account") return { id, profileKind: "default" as const }
        throw new Error("Harness account requires sign-in")
      }),
      activeAccountContext: vi.fn(async () => activeContext),
      markAccountExpired: vi.fn(async () => undefined),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const server = await startWithApp({ ...services, auth })
    runningServers.push(server)

    const projectFolder = mkdtempSync(join(tmpdir(), "codevisor-rebind-project-"))
    tempDirs.push(projectFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        method: "POST",
        body: JSON.stringify({ folderPath: projectFolder })
      })
    ).body as { id: string }

    const pinned = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        harnessAccountId: "dead-account",
        agentSessionId: ""
      })
    )
    await jsonRequest(server, `/v1/sessions/${pinned.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "rebind me" })
    })
    await waitFor(
      async () =>
        (await run(services.db.getSessionSummary(pinned.id))).harnessAccountId === "active-account"
    )
    await waitFor(async () =>
      listSubjectEvents(services, pinned.id).some(
        (event) =>
          event.kind === "session.updated" &&
          typeof event.payload === "object" &&
          event.payload !== null &&
          "harnessAccountId" in event.payload &&
          event.payload.harnessAccountId === "active-account"
      )
    )

    activeContext = { id: "flaky-account", profileKind: "default" }
    const samePin = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        harnessAccountId: "flaky-account",
        agentSessionId: ""
      })
    )
    await jsonRequest(server, `/v1/sessions/${samePin.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "keep my pin" })
    })
    await waitFor(async () => (await run(services.db.listPromptQueue(samePin.id))).length === 0)
    expect((await run(services.db.getSessionSummary(samePin.id))).harnessAccountId).toBe(
      "flaky-account"
    )

    activeContext = undefined
    const stranded = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        harnessAccountId: "dead-account",
        agentSessionId: ""
      })
    )
    await jsonRequest(server, `/v1/sessions/${stranded.id}/prompt`, {
      method: "POST",
      body: JSON.stringify({ text: "stranded" })
    })
    await waitFor(async () =>
      listSubjectEvents(services, stranded.id).some((event) => event.kind === "session.error")
    )
    expect((await run(services.db.getSessionSummary(stranded.id))).harnessAccountId).toBe(
      "dead-account"
    )
  })

  it("answers a pasteCode login flow through the accounts route", async () => {
    const { services } = await makeServices("server-answer")
    const auth = {
      answerLogin: (flowId: string, code: string) =>
        Promise.resolve({ id: flowId, accountId: "a1", kind: "complete", echoed: code }),
      activeAccountContext: () => Promise.resolve(undefined),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const server = await startWithApp({ ...services, auth })

    const answered = await jsonRequest(
      server,
      "/v1/harnesses/claude-code/accounts/a1/login/flow-1/answer",
      { body: JSON.stringify({ code: "abc#def" }), method: "POST" }
    )
    expect(answered.status).toBe(200)
    expect(answered.body).toMatchObject({ id: "flow-1", kind: "complete", echoed: "abc#def" })
  })

  it("capabilities lists sign-in-pending harnesses without inspecting them", async () => {
    const { services, agents } = await makeServices("server-a")
    const auth = {
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
    expect(body.harnesses.some((entry) => entry.harness.id === "codex")).toBe(true)
    const pending = body.harnesses.filter((entry) => !entry.harness.enabled)
    expect(pending.length).toBeGreaterThan(0)
    expect(pending.every((entry) => entry.configOptions.length === 0)).toBe(true)
    expect(agents.inspections.map(([id]) => id)).toEqual(["codex"])
  })
})
