import type { SessionConfigOption } from "@codevisor/api"
import { Effect } from "effect"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import {
  configSelectionsFromTestOptions,
  jsonRequest,
  makeServices,
  run,
  runningServers,
  start,
  startWithApp,
  tempDirs
} from "../test-support.js"

describe("session configuration routes", () => {
  it("persists session config and restores model before dependent reasoning and speed", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-session-config-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-session-config"
      })
    )
    const server = await startWithApp(services)
    runningServers.push(server)

    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    for (const [configId, value] of [
      ["model", "model-saved"],
      ["reasoning", "high"],
      ["speed", "fast"],
      ["tone", "detailed"]
    ] as const) {
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
            body: JSON.stringify({ configId, value }),
            method: "POST"
          })
        ).status
      ).toBe(202)
    }
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
      model: "model-saved",
      reasoning: "high",
      speed: "fast",
      tone: "detailed"
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: {
        configSelections: {
          model: "model-saved",
          reasoning: "high",
          speed: "fast",
          tone: "detailed"
        }
      }
    })

    agents.configs.splice(0)
    const restored = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(agents.configs).toEqual([
      [session.agentSessionId, "model", "model-saved"],
      [session.agentSessionId, "reasoning", "high"],
      [session.agentSessionId, "speed", "fast"],
      [session.agentSessionId, "tone", "detailed"]
    ])
    expect(configSelectionsFromTestOptions(restored.configOptions)).toEqual({
      model: "model-saved",
      reasoning: "high",
      speed: "fast",
      tone: "detailed"
    })

    await run(
      services.db.replaceSessionConfigSelections(session.id, {
        model: "model-removed",
        reasoning: "high",
        speed: "fast",
        tone: "tone-removed",
        "zzz-removed": "unavailable"
      })
    )
    agents.configs.splice(0)
    const fallback = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(agents.configs).toEqual([])
    expect(configSelectionsFromTestOptions(fallback.configOptions)).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
      model: "model-default",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })

    await run(
      services.db.replaceSessionConfigSelections(session.id, {
        model: "model-saved"
      })
    )
    agents.configFailures.push(["agent-session-config", "model", "model-saved"])
    const transientFallback = (
      await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })
    ).body as { readonly configOptions: ReadonlyArray<SessionConfigOption> }
    expect(configSelectionsFromTestOptions(transientFallback.configOptions).model).toBe(
      "model-default"
    )
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual({
      model: "model-saved",
      reasoning: "low",
      speed: "standard",
      tone: "brief"
    })
  })

  it("keeps saved config selections when a session opens with no config options", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-no-config-options-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "claude-code",
        agentSessionId: "agent-no-config-options"
      })
    )
    const saved = { effort: "high", model: "opus[1m]", speed: "standard" }
    await run(services.db.replaceSessionConfigSelections(session.id, saved))
    const server = await startWithApp(services)
    runningServers.push(server)

    const opened = await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect((opened.body as { readonly configOptions: unknown }).configOptions).toEqual([])
    // Nothing to validate against, so nothing is applied — and, above all,
    // nothing is overwritten.
    expect(agents.configs).toEqual([])
    expect(await run(services.db.getSessionConfigSelections(session.id))).toEqual(saved)
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { configSelections: saved }
    })
  })

  it("shares session read and action-required state through the HTTP API", async () => {
    const { server, services } = await start()
    const project = await run(
      services.db.createProject({ folderPath: "/tmp/server-session-attention" })
    )
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )

    expect((await jsonRequest(server, "/v1/sessions")).body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: session.id,
          latestAttentionSequence: 1,
          lastSeenAttentionSequence: 0,
          unreadCount: 1
        })
      ])
    )
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/read`, {
          body: JSON.stringify({}),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/read`, {
          body: JSON.stringify({ throughSequence: 1 }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ lastSeenAttentionSequence: 1, unreadCount: 0 })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/unread`, {
          method: "POST"
        })
      ).body
    ).toMatchObject({ unreadCount: 1 })

    await run(services.db.appendEvent("session.updated", session.id, { modeId: "plan" }))
    await run(
      services.db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-plan",
        turnState: "started"
      })
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        markdown: "# Plan\n\nBuild it.",
        sessionUpdate: "plan_document"
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-plan",
        turnState: "ended"
      })
    )
    expect(await jsonRequest(server, `/v1/sessions/${session.id}`)).toMatchObject({
      body: {
        pendingPlanApproval: true,
        session: {
          actionRequired: true,
          actionRequiredKind: "planApproval",
          pendingPlanApproval: true
        }
      }
    })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/plan-approval`, {
          method: "DELETE"
        })
      ).status
    ).toBe(204)
    expect(await jsonRequest(server, `/v1/sessions/${session.id}`)).toMatchObject({
      body: {
        session: {
          actionRequired: false,
          pendingPlanApproval: false
        }
      }
    })

    expect(
      (await run(services.db.listEvents(0))).filter(
        (event) => event.kind === "session.attention.updated"
      )
    ).toHaveLength(3)
  })

  it("keeps subagent-attributed chunks out of the conversation snapshot", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-subagent-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    mkdirSync(workspaceFolder)
    const workspace = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "Subagent" }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly agentSessionId: string }

    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: {
        content: { text: "main agent text", type: "text" },
        messageId: "assistant-main",
        sessionUpdate: "agent_message_chunk"
      }
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.output",
      subjectId: session.agentSessionId,
      payload: {
        content: { text: "subagent text", type: "text" },
        messageId: "msg-sub-1",
        parentToolCallId: "task-1",
        sessionUpdate: "agent_message_chunk"
      }
    })

    // The raw event is persisted for rich replay (nested transcripts)...
    const events = await run(services.db.listSubjectEvents(session.id))
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ parentToolCallId: "task-1" })
        })
      ])
    )
    // ...but the text conversation snapshot only carries the main thread.
    const detail = await run(services.db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => item.text)).toContain("main agent text")
    expect(detail.conversation.map((item) => item.text)).not.toContain("subagent text")
  })

  it("falls back to the session server's project location for branch diffs", async () => {
    const { services } = await makeServices("server-a")
    const project = await run(services.db.createProject({ folderPath: "/tmp" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const { cwd: _cwd, ...withoutCwd } = session
    let projectedServerId = "server-a"
    const server = await startWithApp({
      ...services,
      db: {
        ...services.db,
        getSessionSummary: (id) =>
          id === session.id
            ? Effect.succeed({ ...withoutCwd, serverId: projectedServerId })
            : services.db.getSessionSummary(id)
      }
    })
    runningServers.push(server)

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
    projectedServerId = "server-without-location"
    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
  })

  it("reports session harness usage limits with workspace and account context", async () => {
    const { services } = await makeServices("server-a")
    const project = await run(services.db.createProject({ folderPath: "/tmp" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const { cwd: _cwd, ...withoutCwd } = session
    let projectedSession = session
    const readHarnessUsageLimits = vi.fn((harnessId: string, cwd: string) =>
      Effect.succeed({
        fetchedAt: "2026-07-15T00:00:00.000Z",
        harnessId,
        state: "available" as const,
        windows: [{ id: "five-hour", label: cwd, usedPercent: 25 }]
      })
    )
    const routeServices = {
      ...services,
      agents: { ...services.agents, readHarnessUsageLimits },
      db: {
        ...services.db,
        getSessionSummary: (id: string) =>
          id === session.id ? Effect.succeed(projectedSession) : services.db.getSessionSummary(id)
      }
    }
    const server = await startWithApp(routeServices)
    runningServers.push(server)

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/usage-limits`)).toMatchObject({
      body: {
        harnessId: "codex",
        state: "available",
        windows: [{ label: "/tmp" }]
      },
      status: 200
    })
    expect((await jsonRequest(server, "/v1/sessions/missing/usage-limits")).status).toBe(404)

    const accounts = [
      {
        id: "other-account",
        harnessId: "codex",
        profileKind: "default" as const,
        label: "Other",
        authState: "authenticated" as const,
        isActive: false,
        canLogin: true,
        canLogout: true
      },
      {
        id: "active-account",
        harnessId: "codex",
        profileKind: "default" as const,
        label: "Active",
        email: "active@example.com",
        authState: "authenticated" as const,
        isActive: true,
        canLogin: true,
        canLogout: true
      }
    ]
    const auth = {
      accounts: vi.fn(async () => accounts),
      accountContext: vi.fn(async (id: string) => ({ id, profileKind: "default" as const })),
      activeAccountContext: vi.fn(async () => ({
        id: "active-account",
        profileKind: "default" as const
      })),
      subscribe: () => () => undefined
    } as unknown as HarnessAuthManager
    const authenticatedServer = await startWithApp({ ...routeServices, auth })
    runningServers.push(authenticatedServer)

    projectedSession = { ...withoutCwd, serverId: "server-a" }
    expect(
      await jsonRequest(authenticatedServer, `/v1/sessions/${session.id}/usage-limits`)
    ).toMatchObject({
      body: {
        accountEmail: "active@example.com",
        accountId: "active-account",
        accountLabel: "Active",
        state: "available"
      },
      status: 200
    })
    expect(auth.activeAccountContext).toHaveBeenCalledWith("codex")

    projectedSession = {
      ...withoutCwd,
      harnessAccountId: "explicit-account",
      serverId: "server-a"
    }
    expect(
      await jsonRequest(authenticatedServer, `/v1/sessions/${session.id}/usage-limits`)
    ).toMatchObject({
      body: { accountId: "explicit-account", state: "available" },
      status: 200
    })
    expect(auth.accountContext).toHaveBeenCalledWith("explicit-account")

    projectedSession = { ...withoutCwd, serverId: "remote-server" }
    expect(
      await jsonRequest(authenticatedServer, `/v1/sessions/${session.id}/usage-limits`)
    ).toMatchObject({
      body: {
        detail: "This session has no local workspace from which to query its harness.",
        harnessId: "codex",
        state: "unavailable",
        windows: []
      },
      status: 200
    })
  })
})
