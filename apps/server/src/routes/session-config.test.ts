import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { usageLimitsObserved } from "@codevisor/agent-runtime"
import { decode } from "@codevisor/api"
import { Effect, Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { makeUsageLimitsCache } from "../infra/usage-limits-cache.js"
import { makeEventFanout } from "../server.js"
import {
  jsonRequest,
  makeServices,
  run,
  start,
  startWithApp,
  tempDirs,
  listEvents,
  listSubjectEvents
} from "../test-support.js"
import { fakeHarnessAuth } from "./harness-auth-test-support.js"
import { idOf } from "./response-test-support.js"
import { sessionEventSink } from "./session-events.js"

describe("session configuration routes", () => {
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
      listEvents(services).filter((event) => event.kind === "session.attention.updated")
    ).toHaveLength(3)
  })

  it("keeps subagent-attributed chunks out of the conversation snapshot", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-subagent-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    mkdirSync(workspaceFolder)
    const workspaceId = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath: workspaceFolder }),
          method: "POST"
        })
      ).body
    )
    const session = decode(Schema.Struct({ id: Schema.String, agentSessionId: Schema.String }))(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: workspaceId, harnessId: "codex", title: "Subagent" }),
          method: "POST"
        })
      ).body
    )

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

    const events = listSubjectEvents(services, session.id)
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ parentToolCallId: "task-1" })
        })
      ])
    )
    const detail = await run(services.db.getSessionDetail(session.id))
    expect(detail.conversation.map((item) => item.text)).toContain("main agent text")
    expect(detail.conversation.map((item) => item.text)).not.toContain("subagent text")
  })

  it("falls back to the session server's project location for branch diffs", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-branch-diff-"))
    tempDirs.push(folder)
    execFileSync("git", ["init", "-b", "main"], { cwd: folder, stdio: "ignore" })
    execFileSync(
      "git",
      ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
      { cwd: folder, stdio: "ignore" }
    )
    writeFileSync(join(folder, "notes.txt"), "one\ntwo\n")
    const project = await run(services.db.createProject({ folderPath: folder }))
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

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: { added: 2, removed: 0 },
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
    const auth = fakeHarnessAuth({
      accounts: vi.fn(async () => accounts),
      accountContext: vi.fn(async (id: string) => ({ id, profileKind: "default" as const })),
      activeAccountContext: vi.fn(async () => ({
        id: "active-account",
        profileKind: "default" as const
      })),
      subscribe: () => () => undefined
    })

    const authenticatedServer = await startWithApp({ ...routeServices, auth })

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

  it("serves live harness usage observations without persisting them or asking again", async () => {
    const { services } = await makeServices("server-a")
    const project = await run(services.db.createProject({ folderPath: "/tmp" }))
    const session = await run(
      services.db.createSession({ projectId: project.id, harnessId: "codex" })
    )
    const readHarnessUsageLimits = vi.fn((harnessId: string) =>
      Effect.succeed({
        fetchedAt: "2026-10-18T00:00:00.000Z",
        harnessId,
        plan: "pro",
        state: "available" as const,
        windows: [{ id: "primary", label: "Weekly limit", usedPercent: 10 }]
      })
    )
    const routeServices = {
      ...services,
      agents: { ...services.agents, readHarnessUsageLimits },
      usageLimits: makeUsageLimitsCache()
    }
    const server = await startWithApp(routeServices)
    const before = listSubjectEvents(routeServices, session.id)
    await jsonRequest(server, `/v1/sessions/${session.id}/usage-limits`)

    await sessionEventSink(
      routeServices,
      await run(makeEventFanout),
      "server-a",
      session.id
    )(
      usageLimitsObserved(
        session.id,
        {
          fetchedAt: "2026-10-18T00:01:00.000Z",
          harnessId: "codex",
          state: "available",
          windows: [{ id: "primary", label: "Weekly limit", usedPercent: 27 }]
        },
        true
      )
    )

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/usage-limits`)).toMatchObject({
      body: { plan: "pro", windows: [{ id: "primary", usedPercent: 27 }] },
      status: 200
    })
    expect(readHarnessUsageLimits).toHaveBeenCalledOnce()
    expect(listSubjectEvents(routeServices, session.id)).toEqual(before)

    await sessionEventSink(
      services,
      await run(makeEventFanout),
      "server-a",
      session.id
    )(
      usageLimitsObserved(session.id, {
        fetchedAt: "2026-10-18T00:02:00.000Z",
        harnessId: "codex",
        state: "available",
        windows: [{ id: "primary", label: "Weekly limit", usedPercent: 50 }]
      })
    )
    expect(listSubjectEvents(services, session.id)).toEqual(before)

    await expect(
      sessionEventSink(
        routeServices,
        await run(makeEventFanout),
        "server-a",
        "missing-session"
      )(
        usageLimitsObserved("missing-session", {
          fetchedAt: "2026-10-18T00:03:00.000Z",
          harnessId: "codex",
          state: "available",
          windows: [{ id: "primary", label: "Weekly limit", usedPercent: 60 }]
        })
      )
    ).resolves.toBeUndefined()
  })
})
