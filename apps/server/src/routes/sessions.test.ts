import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import type { SessionConfigOption } from "@codevisor/api"
import { TerminalError } from "@codevisor/terminal"
import { Effect } from "effect"
import { randomUUID } from "node:crypto"
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import {
  appendAndPublish,
  defaultServerConfig,
  makeEventFanout,
  reconcileOrphanedSessionTurns,
  reconcileStaleStreamingTurns,
  startCodevisorServer,
  type RouteState
} from "../server.js"
import { drainPromptQueue, makeTurnDispatchListener } from "./prompt-queue.js"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import {
  configSelectionsFromTestOptions,
  jsonRequest,
  makeServices,
  readSseEvents,
  readWebSocketEvents,
  run,
  runningServers,
  start,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"

describe("sessions routes", () => {
  it("deleting a workspace's last session deletes the workspace too", async () => {
    const { server, services } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-cascade-project-"))
    tempDirs.push(folder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/workspaces/cascade-ws", {
      body: JSON.stringify({ projectId: project.id, name: "Cascade", hasCustomName: false }),
      method: "PUT"
    })
    const makeSession = async () =>
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: project.id,
            harnessId: "codex",
            workspaceId: "cascade-ws"
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
    const first = await makeSession()
    const second = await makeSession()

    // Deleting one of two: the workspace survives.
    expect(
      (await jsonRequest(server, `/v1/sessions/${first.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(await run(services.db.listWorkspaces)).toHaveLength(1)

    // Deleting the LAST session cascades to the workspace, with the event
    // clients rely on to drop it from their sidebars.
    expect(
      (await jsonRequest(server, `/v1/sessions/${second.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(await run(services.db.listWorkspaces)).toHaveLength(0)
    const events = await run(services.db.listEvents(0))
    expect(events.some((event) => event.kind === "workspace.deleted")).toBe(true)
  })

  it("terminalizes orphaned durable state and restores the agent only when the chat connects", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-recovery-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-before-crash"
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "orphaned-turn",
        turnState: "started"
      })
    )

    const backgroundOnly = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "background-only-agent"
      })
    )
    await run(
      services.db.appendEvent("session.updated", backgroundOnly.id, {
        backgroundTasks: [
          {
            id: "background-only-task",
            description: "Run detached work",
            status: "running",
            taskType: "shell"
          }
        ]
      })
    )
    const archived = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "archived-agent"
      })
    )
    await run(
      services.db.appendEvent("session.updated", archived.id, {
        initiatedBy: "user",
        turnId: "archived-turn",
        turnState: "started"
      })
    )
    await run(services.db.archiveSession(archived.id))
    // A concurrent-writer incident can strand a streaming row mid-transcript:
    // the conversation moved past it, so it is not the newest item and no
    // future terminal event can ever close it.
    const splitBrain = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "split-brain-agent"
      })
    )
    await run(
      services.db.appendConversationItem(
        splitBrain.id,
        "assistant",
        "stale-message",
        "half-finished answer",
        true
      )
    )
    await run(
      services.db.appendConversationItem(splitBrain.id, "user", "follow-up", "hello again", false)
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        sessionUpdate: "question",
        questionId: "orphaned-question",
        questions: [
          {
            id: "choice",
            question: "Continue?",
            options: [{ label: "Yes" }],
            allowsOther: false
          }
        ]
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          {
            id: "orphaned-background-task",
            description: "Run checks",
            status: "running",
            taskType: "shell"
          }
        ]
      })
    )

    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(server)

    // Startup recovery must stay database-only. A cold provider process can
    // take tens of seconds to initialize, and health/chat history do not need
    // it yet.
    expect(agents.loads).toEqual([])
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.pendingQuestion).toBeUndefined()
    expect(page.backgroundTasks).toEqual([])
    expect(
      (await run(services.db.getTranscriptPage(backgroundOnly.id, undefined, 8))).backgroundTasks
    ).toEqual([])
    // Archived sessions get no turn restoration, but their stale streaming
    // rows are still closed — unarchiving must not resurface an endless
    // in-progress turn.
    expect(
      (await run(services.db.getTranscriptPage(archived.id, undefined, 8))).items.at(-1)
    ).toMatchObject({
      isGenerating: false,
      stopReason: "interrupted",
      stopDetail: "The server restarted before this response finished."
    })
    const splitPage = await run(services.db.getTranscriptPage(splitBrain.id, undefined, 8))
    expect(splitPage.items.map((item) => item.isGenerating)).toEqual([false, false])
    expect(splitPage.items.at(0)).toMatchObject({
      role: "assistant",
      isGenerating: false,
      stopReason: "interrupted",
      stopDetail: "The server restarted before this response finished."
    })
    expect(page.items.at(-1)).toMatchObject({
      isGenerating: false,
      stopReason: "interrupted",
      stopDetail:
        "The server restarted before this turn finished. Reopen the chat to reconnect its agent session, then send a message to continue."
    })
    const events = await run(services.db.listSubjectEvents(session.id))
    expect(events.map((event) => event.payload)).toContainEqual(
      expect.objectContaining({
        outcome: "cancelled",
        questionId: "orphaned-question",
        sessionUpdate: "question_resolved"
      })
    )
    expect(events.map((event) => event.payload)).toContainEqual(
      expect.objectContaining({
        stopReason: "interrupted",
        turnId: "orphaned-turn",
        turnState: "ended"
      })
    )

    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    expect(agents.loads).toEqual([["codex", "agent-before-crash", folder]])
  })

  it("returns cancel success only after the durable transcript is terminal", async () => {
    const { agents, services } = await makeServices("server-a")
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const folder = mkdtempSync(join(tmpdir(), "codevisor-cancel-durable-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-cancel-durable"
      })
    )
    let cancelCount = 0
    const durableAgents: AgentRuntimeService = {
      ...agents,
      cancel: (agentSessionId) =>
        Effect.promise(async () => {
          cancelCount += 1
          await agents.emit(agentSessionId, {
            kind: "session.updated",
            subjectId: agentSessionId,
            payload: {
              initiatedBy: "user",
              stopReason: "cancelled",
              turnId: "stuck-turn",
              turnState: "ended"
            }
          })
          return { runtimeState: "retire" as const }
        })
    }
    const server = await startWithApp({ ...services, agents: durableAgents })
    runningServers.push(server)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
          method: "POST"
        })
      ).status
    ).toBe(200)
    const agentSessionId = session.agentSessionId
    if (agentSessionId === undefined) throw new Error("expected persisted agent session id")
    await agents.emit(agentSessionId, {
      kind: "session.updated",
      subjectId: agentSessionId,
      payload: { initiatedBy: "user", turnId: "stuck-turn", turnState: "started" }
    })
    expect((await run(services.db.getSessionDetail(session.id))).conversation.at(-1)).toMatchObject(
      {
        isGenerating: true,
        role: "assistant"
      }
    )

    const response = await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
      body: JSON.stringify({ clientActionId: "durable-cancel-1" }),
      method: "POST"
    })

    expect(response).toMatchObject({ body: { cancelled: true }, status: 202 })
    expect(cancelCount).toBe(1)
    expect(
      (await run(services.db.getTranscriptPage(session.id, undefined, 8))).items.at(-1)
    ).toMatchObject({
      isGenerating: false,
      role: "assistant",
      stopReason: "cancelled"
    })
    expect(errors).toHaveBeenCalledWith(expect.stringContaining('"event":"agent_cancel_forced"'))
    expect(errors).toHaveBeenCalledWith(expect.stringContaining(`"sessionId":"${session.id}"`))
  })

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

  it("terminalizes a durably claimed prompt instead of losing or replaying it after restart", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-claimed-prompt-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-before-prompt-crash"
      })
    )
    const queued = await run(services.db.createPromptQueueItem(session.id, "do not lose me"))
    expect(await run(services.db.claimPromptQueueItem(session.id))).toMatchObject({ id: queued.id })

    const completedSession = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-after-complete"
      })
    )
    const completed = await run(
      services.db.createPromptQueueItem(completedSession.id, "already finished")
    )
    await run(services.db.claimPromptQueueItem(completedSession.id))
    await run(
      services.db.appendEvent("session.output", completedSession.id, {
        role: "user",
        messageId: completed.id,
        text: completed.text
      })
    )
    await run(
      services.db.appendEvent("session.output", completedSession.id, {
        role: "assistant",
        text: "done"
      })
    )
    await run(
      services.db.appendEvent("session.updated", completedSession.id, {
        stopReason: "end_turn"
      })
    )

    const dispatchedSession = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-after-user-dispatch"
      })
    )
    const attachment = {
      fileId: "durable-file",
      name: "recovery.txt",
      mimeType: "text/plain",
      sizeBytes: 8,
      kind: "file" as const
    }
    const attachedMissingSession = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-before-attached-dispatch"
      })
    )
    await run(
      services.db.createPromptQueueItem(attachedMissingSession.id, "dispatch attachment", [
        attachment
      ])
    )
    await run(services.db.claimPromptQueueItem(attachedMissingSession.id))
    const dispatched = await run(
      services.db.createPromptQueueItem(dispatchedSession.id, "already dispatched", [attachment])
    )
    await run(services.db.claimPromptQueueItem(dispatchedSession.id))
    await run(
      services.db.appendEvent("session.output", dispatchedSession.id, {
        role: "user",
        messageId: dispatched.id,
        text: dispatched.text,
        attachments: [attachment]
      })
    )

    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(server)

    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.items).toMatchObject([
      { role: "user", text: "do not lose me", isGenerating: false },
      { role: "assistant", stopReason: "interrupted", isGenerating: false }
    ])
    expect(await run(services.db.listPromptQueue(session.id))).toEqual([])
    expect(await run(services.db.listProcessingPromptQueue(session.id))).toEqual([])

    const completedPage = await run(
      services.db.getTranscriptPage(completedSession.id, undefined, 8)
    )
    expect(completedPage.items).toMatchObject([
      { role: "user", text: "already finished" },
      { role: "assistant", text: "done", stopReason: "end_turn" }
    ])
    expect(await run(services.db.listProcessingPromptQueue(completedSession.id))).toEqual([])

    const dispatchedPage = await run(
      services.db.getTranscriptPage(dispatchedSession.id, undefined, 8)
    )
    expect(dispatchedPage.items).toMatchObject([
      { role: "user", text: "already dispatched", attachments: [attachment] },
      { role: "assistant", stopReason: "interrupted" }
    ])
    expect(await run(services.db.listProcessingPromptQueue(dispatchedSession.id))).toEqual([])
    expect(await run(services.db.listProcessingPromptQueue(attachedMissingSession.id))).toEqual([])

    const before = await run(services.db.listSubjectEvents(session.id))
    await reconcileOrphanedSessionTurns(services, await run(makeEventFanout), "server-a")
    expect(await run(services.db.listSubjectEvents(session.id))).toHaveLength(before.length)
  })

  it("terminalizes an orphaned turn even when its agent session cannot be restored yet", async () => {
    const { agents, services } = await makeServices("server-a")
    const missingFolder = join(tmpdir(), `codevisor-missing-${randomUUID()}`)
    const project = await run(services.db.createProject({ folderPath: missingFolder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "unrestorable-agent"
      })
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "partial answer"
      })
    )

    const server = await run(
      startCodevisorServer(services, defaultServerConfig({ id: "server-a", port: 0 }))
    )
    runningServers.push(server)

    expect(agents.loads).toEqual([])
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [
        {
          isGenerating: false,
          stopReason: "interrupted",
          stopDetail: expect.stringContaining("Reopen the chat to reconnect its agent session")
        }
      ]
    })
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(400)
    expect(agents.loads).toEqual([])
  })

  it("sweeps quiet orphaned streaming turns while the server keeps running", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-stale-sweep-"))
    tempDirs.push(folder)
    const emptyRouteState = (): RouteState => ({
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {}
    })

    // Strand a turn "in the past": its harness died (or its terminal event
    // was lost) six minutes ago and nothing has been appended since.
    const strandedSession = async () => {
      const project = await run(services.db.createProject({ folderPath: folder }))
      const created = await run(
        services.db.createSession({
          projectId: project.id,
          harnessId: "codex",
          agentSessionId: "stale-sweep-agent"
        })
      )
      await run(
        services.db.appendEvent("session.updated", created.id, {
          initiatedBy: "user",
          turnId: "stale-sweep-turn",
          turnState: "started"
        })
      )
      await run(
        services.db.appendEvent("session.output", created.id, {
          role: "assistant",
          text: "half-finished answer"
        })
      )
      // The turn died while a question was pending; the sweep must pair it
      // before ending the turn.
      await run(
        services.db.appendEvent("session.output", created.id, {
          sessionUpdate: "question",
          questionId: "stale-sweep-question",
          questions: [
            {
              id: "choice",
              question: "Continue?",
              options: [{ label: "Yes" }],
              allowsOther: false
            }
          ]
        })
      )
      // A second stranded row that never had turn accounting: the terminal
      // event must close it without turn fields.
      const turnless = await run(
        services.db.createSession({
          projectId: project.id,
          harnessId: "codex",
          agentSessionId: "stale-sweep-turnless"
        })
      )
      await run(
        services.db.appendEvent("session.output", turnless.id, {
          role: "assistant",
          text: "no turn id"
        })
      )
      // A streaming row stranded mid-transcript (the conversation moved past
      // it): repaired without a terminal event, since the newest item is not
      // an in-progress turn.
      const midTranscript = await run(
        services.db.createSession({
          projectId: project.id,
          harnessId: "codex",
          agentSessionId: "stale-sweep-mid-transcript"
        })
      )
      await run(
        services.db.appendConversationItem(
          midTranscript.id,
          "assistant",
          "stale-mid-message",
          "half-finished answer",
          true
        )
      )
      await run(
        services.db.appendConversationItem(midTranscript.id, "user", "follow-up", "hello?", false)
      )
      return { session: created, turnless, midTranscript }
    }
    vi.useFakeTimers({ toFake: ["Date"] })
    let session!: Awaited<ReturnType<typeof strandedSession>>["session"]
    let turnless!: Awaited<ReturnType<typeof strandedSession>>["turnless"]
    let midTranscript!: Awaited<ReturnType<typeof strandedSession>>["midTranscript"]
    try {
      vi.setSystemTime(Date.now() - 6 * 60 * 1000)
      ;({ session, turnless, midTranscript } = await strandedSession())
    } finally {
      vi.useRealTimers()
    }

    const fanout = await run(makeEventFanout)

    // A drain that still owns the session's turn keeps the sweep away: long
    // silent tool runs are quiet on the event log but perfectly alive.
    const owned = emptyRouteState()
    owned.activePromptSessions.add(session.id)
    owned.activePromptSessions.add(turnless.id)
    owned.activePromptSessions.add(midTranscript.id)
    expect(await reconcileStaleStreamingTurns(services, fanout, owned, "server-a")).toBe(0)
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [{ role: "assistant", isGenerating: true }]
    })

    // Unowned and quiet: the sweep closes every stranded row.
    expect(
      await reconcileStaleStreamingTurns(services, fanout, emptyRouteState(), "server-a")
    ).toBe(3)
    const repairedPage = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(repairedPage).toMatchObject({
      items: [
        {
          role: "assistant",
          isGenerating: false,
          stopReason: "interrupted",
          stopDetail: expect.stringContaining("stopped streaming")
        }
      ]
    })
    // The orphaned question was paired before the turn ended.
    expect(repairedPage.pendingQuestion).toBeUndefined()
    // The turnless row is closed by a terminal event without turn fields.
    expect(await run(services.db.getTranscriptPage(turnless.id, undefined, 8))).toMatchObject({
      items: [{ role: "assistant", isGenerating: false, stopReason: "interrupted" }]
    })
    // The mid-transcript row is repaired quietly — the conversation had
    // already moved on, so no terminal turn event is published.
    expect(await run(services.db.getTranscriptPage(midTranscript.id, undefined, 8))).toMatchObject({
      items: [
        { role: "assistant", isGenerating: false, stopReason: "interrupted" },
        { role: "user", text: "hello?" }
      ]
    })
    // The repair flows through the event pipeline: connected clients receive
    // a live terminal event instead of discovering the row on a full reload.
    const events = await run(services.db.listSubjectEvents(session.id))
    expect(events.map((event) => event.kind)).toContain("session.updated")
    expect(
      events.some(
        (event) =>
          event.kind === "session.updated" &&
          typeof event.payload === "object" &&
          event.payload !== null &&
          (event.payload as { stopReason?: string }).stopReason === "interrupted"
      )
    ).toBe(true)

    // Idempotent: nothing left to repair.
    expect(
      await reconcileStaleStreamingTurns(services, fanout, emptyRouteState(), "server-a")
    ).toBe(0)
  })

  it("spares streaming turns with recent event activity", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-live-sweep-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "live-sweep-agent"
      })
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "still streaming right now"
      })
    )

    const fanout = await run(makeEventFanout)
    const routeState: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {}
    }
    expect(await reconcileStaleStreamingTurns(services, fanout, routeState, "server-a")).toBe(0)
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [{ role: "assistant", isGenerating: true }]
    })
  })

  it("holds prompt dispatch while a harness-initiated turn is active and re-drains when it ends", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-turn-hold-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-turn-hold"
      })
    )
    const fanout = await run(makeEventFanout)
    const routeState: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {}
    }
    const unsubscribe = fanout.subscribe(
      makeTurnDispatchListener(services, fanout, routeState, "server-a")
    )

    // The harness started a turn on its own (a task-notification follow-up
    // after a background task finished) — no prompt drain owns it.
    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      initiatedBy: "agent",
      turnId: "agent-turn-1",
      turnState: "started"
    })
    expect(routeState.activeTurnSessions.has(session.id)).toBe(true)

    // A prompt sent mid-turn stays queued instead of being injected into the
    // live turn (where the turn's result would resolve it prematurely).
    await run(services.db.createPromptQueueItem(session.id, "queued behind agent turn"))
    await drainPromptQueue(services, fanout, routeState, "server-a", session.id)
    expect(agents.prompts).toEqual([])
    expect(routeState.turnHeldSessions.has(session.id)).toBe(true)
    expect(await run(services.db.listPromptQueue(session.id))).toMatchObject([
      { text: "queued behind agent turn" }
    ])

    // The turn's terminal event releases the hold and dispatches the prompt.
    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      initiatedBy: "agent",
      stopReason: "end_turn",
      turnId: "agent-turn-1",
      turnState: "ended"
    })
    await waitFor(
      () => agents.prompts.length === 1,
      () => `prompts: ${JSON.stringify(agents.prompts)}`
    )
    expect(agents.prompts[0]).toEqual(["agent-turn-hold", "queued behind agent turn"])
    await waitFor(async () => (await run(services.db.listPromptQueue(session.id))).length === 0)
    expect(routeState.activeTurnSessions.has(session.id)).toBe(false)
    expect(routeState.turnHeldSessions.has(session.id)).toBe(false)

    // Malformed payloads are tolerated: a terminal event whose payload is not
    // an object still clears the turn instead of throwing.
    const listener = makeTurnDispatchListener(services, fanout, routeState, "server-a")
    for (const malformed of ["boom", null, ["boom"]]) {
      routeState.activeTurnSessions.add(session.id)
      listener({
        id: 999,
        serverId: "server-a",
        kind: "session.error",
        subjectId: session.id,
        createdAt: "2026-08-23T00:00:00.000Z",
        payload: malformed
      } as never)
      expect(routeState.activeTurnSessions.has(session.id)).toBe(false)
    }
    unsubscribe()
  })

  it("holds the next queued prompt when a turn begins mid-drain", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-middrain-hold-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent-middrain-hold"
      })
    )
    const fanout = await run(makeEventFanout)
    const routeState: RouteState = {
      activePromptSessions: new Set(),
      activeTurnSessions: new Set(),
      gatedSessions: new Map(),
      pendingPromptActions: new Set(),
      pendingSessionCreates: new Map(),
      turnHeldSessions: new Set(),
      updateSignature: {}
    }
    // Simulate a task-notification turn starting the instant the first
    // dispatched turn ends — before the drain loop claims the next item.
    const unsubscribe = fanout.subscribe((event) => {
      const payload = event.payload as Record<string, unknown>
      if (event.kind === "session.updated" && payload.turnState === "ended") {
        routeState.activeTurnSessions.add(session.id)
      }
    })

    await run(services.db.createPromptQueueItem(session.id, "first"))
    await run(services.db.createPromptQueueItem(session.id, "second"))
    await drainPromptQueue(services, fanout, routeState, "server-a", session.id)

    expect(agents.prompts).toEqual([["agent-middrain-hold", "first"]])
    expect(routeState.turnHeldSessions.has(session.id)).toBe(true)
    expect(await run(services.db.listPromptQueue(session.id))).toMatchObject([{ text: "second" }])
    unsubscribe()
  })

  it("adopts a client-supplied messageId as the queue item and echo id", async () => {
    const { services } = await makeServices("server-prompt-message-id")
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "server-prompt-message-id", port: 0 })
      )
    )
    runningServers.push(server)
    const folder = join(mkdtempSync(join(tmpdir(), "codevisor-prompt-id-")), "repo")
    mkdirSync(folder, { recursive: true })
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: folder }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: project.id, harnessId: "codex", title: "Identity" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const messageId = "0f6b2c8e-8a34-4b9d-9f2e-1a7c5d3e9b01"
    const accepted = await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
      body: JSON.stringify({ text: "run pwd", messageId }),
      method: "POST"
    })
    expect(accepted.status).toBe(202)
    expect((accepted.body as { queueItemId?: string }).queueItemId).toBe(messageId)

    // The user echo event carries the client's id back, so clients can
    // reconcile their optimistic message by identity.
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(session.id))).some(
        (event) =>
          event.kind === "session.output" &&
          (event.payload as { messageId?: string }).messageId === messageId &&
          (event.payload as { role?: string }).role === "user"
      )
    )
  })

  it("manages workspaces, harnesses, sessions, actions, and event replay", async () => {
    const { agents, server, services } = await start()
    const workspaceRoot = mkdtempSync(join(tmpdir(), "codevisor-server-workspace-"))
    tempDirs.push(workspaceRoot)
    const workspaceFolder = join(workspaceRoot, "codevisor")
    const noModesFolder = join(workspaceRoot, "no-modes")
    const capabilityFailFolder = join(workspaceRoot, "capability-fail")
    const cwdFile = join(workspaceRoot, "cwd-file")
    mkdirSync(workspaceFolder)
    mkdirSync(noModesFolder)
    mkdirSync(capabilityFailFolder)
    writeFileSync(cwdFile, "")
    const legacyRoot = mkdtempSync(join(tmpdir(), "codevisor-server-legacy-"))
    tempDirs.push(legacyRoot)
    const legacyWorkspaceFolder = join(legacyRoot, "legacy-agent-session")
    mkdirSync(legacyWorkspaceFolder)
    const badJson = await fetch(`${server.url}/v1/projects`, {
      body: "{",
      headers: { "Content-Type": "application/json" },
      method: "POST"
    })
    expect(badJson.status).toBe(400)
    expect((await jsonRequest(server, "/v1/missing")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/not-sessions/session-a/queue/item-a")).status).toBe(404)

    const workspaceResponse = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: workspaceFolder, id: "workspace-client-id" }),
      method: "POST"
    })
    expect(workspaceResponse.status).toBe(201)
    const workspace = workspaceResponse.body as { readonly id: string }
    expect(workspace.id).toBe("workspace-client-id")
    expect((await jsonRequest(server, "/v1/projects")).body).toMatchObject([{ id: workspace.id }])
    expect(
      (
        await jsonRequest(server, `/v1/projects/${workspace.id}`, {
          body: JSON.stringify({ name: "Renamed" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ name: "Renamed" })

    expect((await jsonRequest(server, "/v1/harnesses")).body).toMatchObject([
      { id: "codex", enabled: true, installHint: "npm install -g @openai/codex" }
    ])

    // Rescan re-resolves the runtime environment, then returns the fresh list.
    const rescanResponse = await jsonRequest(server, "/v1/harnesses/rescan", { method: "POST" })
    expect(rescanResponse.status).toBe(200)
    expect(rescanResponse.body).toMatchObject([{ id: "codex", enabled: true }])
    expect(agents.environmentRefreshes).toHaveLength(1)

    // Native agent sessions come from the harness's own store via the runtime.
    expect((await jsonRequest(server, "/v1/harnesses/codex/agent-sessions")).body).toEqual([
      { sessionId: "native-1", cwd: "/repo/native", title: "Old codex chat" }
    ])
    expect((await jsonRequest(server, "/v1/harnesses/gemini/agent-sessions")).body).toEqual([])
    const capabilitiesResponse = await jsonRequest(
      server,
      `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}`
    )
    expect(capabilitiesResponse.body).toMatchObject({
      harnesses: [
        {
          harness: { id: "codex" },
          modes: { currentModeId: "default" },
          configOptions: [
            { category: "model", currentValue: "gpt-5", id: "model" },
            { category: "thought_level", currentValue: "medium", id: "reasoning" }
          ],
          supportsGoals: true
        }
      ]
    })
    expect(agents.inspections).toEqual([["codex", workspaceFolder]])
    expect(agents.inspectionConfigs).toEqual([undefined])
    agents.inspections.splice(0)
    agents.inspectionConfigs.splice(0)
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}&harnessId=missing`
        )
      ).body
    ).toEqual({ harnesses: [] })
    expect(agents.inspections).toEqual([])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}&harnessId=codex`
        )
      ).body
    ).toMatchObject({ harnesses: [{ harness: { id: "codex" } }] })
    expect(agents.inspections).toEqual([["codex", workspaceFolder]])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(workspaceFolder)}&harnessId=codex&config.model=gpt-next`
        )
      ).body
    ).toMatchObject({
      harnesses: [
        {
          configOptions: [
            { currentValue: "gpt-next", id: "model" },
            { currentValue: "high", id: "reasoning" }
          ]
        }
      ]
    })
    expect(agents.inspectionConfigs.at(-1)).toEqual({ model: "gpt-next" })
    expect((await jsonRequest(server, "/v1/capabilities")).body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    const missingCwdCapabilities = await jsonRequest(
      server,
      "/v1/capabilities?cwd=%2Ftmp%2Fmissing-codevisor-workspace"
    )
    expect(missingCwdCapabilities.body).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(
      (
        missingCwdCapabilities.body as {
          readonly harnesses: ReadonlyArray<{
            readonly configOptions: ReadonlyArray<{ readonly id: string }>
          }>
        }
      ).harnesses[0]?.configOptions.map((option) => option.id)
    ).toContain("model")
    expect(agents.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(cwdFile)}`)).body
    ).toMatchObject({
      harnesses: [{ harness: { id: "codex" } }]
    })
    expect(agents.inspections.at(-1)).toEqual(["codex", tmpdir()])
    expect(
      (await jsonRequest(server, `/v1/capabilities?cwd=${encodeURIComponent(noModesFolder)}`)).body
    ).toMatchObject({
      harnesses: [{ configOptions: [], harness: { id: "codex" } }]
    })
    expect(
      (
        await jsonRequest(
          server,
          `/v1/capabilities?cwd=${encodeURIComponent(capabilityFailFolder)}`
        )
      ).body
    ).toMatchObject({
      harnesses: [{ configOptions: [], harness: { id: "codex" } }]
    })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/codex", {
          body: JSON.stringify({ enabled: false }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ id: "codex", enabled: false })
    expect(
      (
        await jsonRequest(server, "/v1/harnesses/missing", {
          body: JSON.stringify({ enabled: true }),
          method: "PATCH"
        })
      ).status
    ).toBe(404)

    const sessionResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: workspace.id, harnessId: "codex", title: "First chat" }),
      method: "POST"
    })
    const session = sessionResponse.body as { readonly id: string; readonly agentSessionId: string }
    expect(session.agentSessionId).toBe("agent-codex-codevisor")
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "  Harness-generated title  " }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "Harness-generated title" }
    })
    // Repeating the current harness title is an idempotent no-op.
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        sessionUpdate: "session_info_update",
        title: "Harness-generated title"
      }
    })
    // A missing/blank harness title keeps the existing first-prompt fallback.
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: { sessionUpdate: "session_info_update", title: "   " }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "Harness-generated title" }
    })
    await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ title: "User-provided title" }),
      method: "PATCH"
    })
    await agents.emit(session.agentSessionId, {
      kind: "session.updated",
      subjectId: session.agentSessionId,
      payload: {
        sessionUpdate: "session_info_update",
        title: "Later harness-generated title"
      }
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { title: "User-provided title" }
    })
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: session.id,
            projectId: workspace.id,
            harnessId: "codex",
            title: "First chat"
          }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ agentSessionId: "agent-codex-codevisor", id: session.id })

    const deferredResponse = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: workspace.id,
        harnessId: "codex",
        title: "Deferred chat",
        deferAgentSession: true
      }),
      method: "POST"
    })
    const deferred = deferredResponse.body as {
      readonly id: string
      readonly agentSessionId?: string
    }
    expect(deferred.agentSessionId).toBe("")
    expect(agents.creations).toEqual([["codex", workspaceFolder]])
    await jsonRequest(server, `/v1/sessions/${deferred.id}/prompt`, {
      body: JSON.stringify({ text: "hello deferred" }),
      method: "POST"
    })
    await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello deferred"))
    const deferredDetail = (await jsonRequest(server, `/v1/sessions/${deferred.id}`)).body as {
      readonly session: { readonly agentSessionId?: string }
    }
    expect(deferredDetail.session.agentSessionId).toBe("agent-codex-codevisor")
    expect(agents.prompts).toContainEqual(["agent-codex-codevisor", "hello deferred"])

    const concurrentSessionBody = JSON.stringify({
      id: "client-session-concurrent",
      projectId: workspace.id,
      harnessId: "codex",
      title: "Concurrent chat"
    })
    const workspaceCreationsBeforeConcurrent = agents.creations.filter(
      (creation) => creation[1] === workspaceFolder
    ).length
    const [firstConcurrent, secondConcurrent] = await Promise.all([
      jsonRequest(server, "/v1/sessions", {
        body: concurrentSessionBody,
        method: "POST"
      }),
      jsonRequest(server, "/v1/sessions", {
        body: concurrentSessionBody,
        method: "POST"
      })
    ])
    expect([firstConcurrent.status, secondConcurrent.status].sort()).toEqual([200, 201])
    expect(firstConcurrent.body).toMatchObject({
      agentSessionId: "agent-codex-codevisor",
      id: "client-session-concurrent"
    })
    expect(secondConcurrent.body).toEqual(firstConcurrent.body)
    expect(agents.creations.filter((creation) => creation[1] === workspaceFolder)).toHaveLength(
      workspaceCreationsBeforeConcurrent + 1
    )

    expect(await jsonRequest(server, "/v1/sessions")).toMatchObject({
      body: expect.arrayContaining([expect.objectContaining({ id: session.id })])
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}`)).body).toMatchObject({
      session: { id: session.id }
    })
    expect(await jsonRequest(server, `/v1/sessions/${session.id}/branch-diff`)).toEqual({
      body: null,
      status: 200
    })
    expect((await jsonRequest(server, "/v1/sessions/missing/branch-diff")).status).toBe(404)
    expect(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            id: "client-session-id",
            projectId: "missing",
            harnessId: "codex"
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
    const missingWorkspaceResponse = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({
        folderPath: "/tmp/codevisor-missing-session-workspace",
        id: "missing-folder-workspace"
      }),
      method: "POST"
    })
    expect(missingWorkspaceResponse.status).toBe(201)
    expect(
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "missing-folder-workspace",
          harnessId: "codex"
        }),
        method: "POST"
      })
    ).toEqual({
      body: { error: "Project folder does not exist: /tmp/codevisor-missing-session-workspace" },
      status: 400
    })
    expect((await jsonRequest(server, "/v1/sessions/missing")).status).toBe(500)

    const promptCountBeforeHello = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeHello + 1)
    expect(agents.prompts).toContainEqual([session.agentSessionId, "hello"])
    const promptCountBeforeRetry = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ clientActionId: "prompt-retry-1", text: "retry once" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeRetry + 1)
    expect(agents.prompts).toEqual(
      expect.arrayContaining([
        [session.agentSessionId, "hello"],
        [session.agentSessionId, "retry once"]
      ])
    )
    const promptCountBeforeRawChunks = agents.prompts.length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "raw chunks" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeRawChunks + 1)
    let rawConversation: ReadonlyArray<string> = []
    let rawEvents: ReadonlyArray<unknown> = []
    await waitFor(
      async () => {
        rawConversation = (await run(services.db.getSessionDetail(session.id))).conversation.map(
          (item) => item.text
        )
        rawEvents = await run(services.db.listSubjectEvents(session.id))
        return rawConversation.includes("Raw answer without id")
      },
      () => JSON.stringify({ rawConversation, rawEvents })
    )
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(
      expect.arrayContaining(["hello", "Echo: hello", "raw chunks", "Raw answer without id"])
    )
    expect(await run(services.db.listSubjectEvents(session.id))).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          kind: "session.output",
          payload: expect.objectContaining({ sessionUpdate: "agent_message_chunk" })
        })
      ])
    )
    // The per-session history endpoint returns only this session's envelopes.
    const historyResponse = await jsonRequest(server, `/v1/sessions/${session.id}/events`)
    expect(historyResponse.status).toBe(200)
    const history = historyResponse.body as Array<{ subjectId: string; kind: string }>
    expect(history.length).toBeGreaterThan(0)
    expect(history.every((event) => event.subjectId === session.id)).toBe(true)
    const scopedReplay = (await readWebSocketEvents(
      server,
      2,
      0,
      `/v1/sessions/${session.id}/events/socket`
    )) as Array<{ id: number; subjectId: string; subjectRevision?: number }>
    expect(scopedReplay.every((event) => event.subjectId === session.id)).toBe(true)
    expect(scopedReplay.map((event) => event.id)).toEqual([1, 2])
    expect(scopedReplay.map((event) => event.subjectRevision)).toEqual([1, 2])
    const transcriptResponse = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/transcript?limit=2`
    )
    expect(transcriptResponse.status).toBe(200)
    const transcript = transcriptResponse.body as {
      items: Array<{ id: string; role: string; text: string }>
      hasMore: boolean
      eventCursor: number
    }
    expect(transcript.items.length).toBeLessThanOrEqual(2)
    expect(transcript.items.some((item) => item.role === "assistant")).toBe(true)
    expect(transcript.eventCursor).toBeGreaterThan(0)
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/transcript`)).status).toBe(200)
    const assistantTranscriptItem = transcript.items.find((item) => item.role === "assistant")!
    const transcriptDetails = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/transcript/${assistantTranscriptItem.id}/details`
    )
    expect(transcriptDetails.status).toBe(200)
    expect(transcriptDetails.body).toMatchObject({ itemId: assistantTranscriptItem.id })
    expect(
      (
        transcriptDetails.body as {
          events: Array<{ subjectId: string }>
        }
      ).events.every((event) => event.subjectId === session.id)
    ).toBe(true)
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?before=wat`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?before=-1`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?limit=wat`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript?limit=0`)
    ).toMatchObject({ status: 400 })
    expect(
      await jsonRequest(server, `/v1/sessions/${session.id}/transcript/missing/details`)
    ).toMatchObject({ status: 404 })
    const promptCountBeforeReturnedEvents = agents.prompts.length
    const queueEventsBeforeReturnedEvents = (
      await run(services.db.listSubjectEvents(session.id))
    ).filter((event) => event.kind === "session.queue.updated").length
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "returned events" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(() => agents.prompts.length === promptCountBeforeReturnedEvents + 1)
    expect(
      (await run(services.db.getSessionDetail(session.id))).conversation.map((item) => item.text)
    ).toEqual(expect.arrayContaining(["returned events", "Raw answer without id"]))
    await waitFor(async () => {
      const processing = await run(services.db.listProcessingPromptQueue(session.id))
      const queueEventCount = (await run(services.db.listSubjectEvents(session.id))).filter(
        (event) => event.kind === "session.queue.updated"
      ).length
      return processing.length === 0 && queueEventCount >= queueEventsBeforeReturnedEvents + 2
    })

    const promptCountBeforeSlow = agents.prompts.length
    const queueEventsBeforeSlow = (await run(services.db.listSubjectEvents(session.id))).filter(
      (event) => event.kind === "session.queue.updated"
    ).length
    const slowResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "slow prompt" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect(slowResponse.queueItemId).toBeTypeOf("string")
    await waitFor(() => agents.prompts.length === promptCountBeforeSlow + 1)
    const immediatePromptQueueEvents = (await run(services.db.listSubjectEvents(session.id)))
      .filter((event) => event.kind === "session.queue.updated")
      .slice(queueEventsBeforeSlow)
    expect(immediatePromptQueueEvents).not.toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          payload: expect.objectContaining({
            queue: expect.arrayContaining([
              expect.objectContaining({ id: slowResponse.queueItemId })
            ])
          })
        })
      ])
    )
    const queuedResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "queued original" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    const removedResponse = (
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "queued remove" }),
        method: "POST"
      })
    ).body as { readonly queueItemId: string }
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/queue`)).body).toMatchObject([
      { id: queuedResponse.queueItemId, text: "queued original" },
      { id: removedResponse.queueItemId, text: "queued remove" }
    ])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/queue`, {
          body: JSON.stringify({
            queueItemIds: [removedResponse.queueItemId, queuedResponse.queueItemId]
          }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject([
      { id: removedResponse.queueItemId, text: "queued remove" },
      { id: queuedResponse.queueItemId, text: "queued original" }
    ])
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/queue/${queuedResponse.queueItemId}`,
          {
            body: JSON.stringify({ text: "queued edited" }),
            method: "PATCH"
          }
        )
      ).body
    ).toMatchObject({ text: "queued edited" })
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/queue/${removedResponse.queueItemId}`,
          { method: "DELETE" }
        )
      ).status
    ).toBe(204)
    const promptCountBeforeQueueDrain = agents.prompts.length
    await waitFor(() => agents.prompts.length === promptCountBeforeQueueDrain + 1)
    expect(agents.prompts).toContainEqual([session.agentSessionId, "queued edited"])
    expect(agents.prompts).not.toContainEqual([session.agentSessionId, "queued remove"])

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
          body: JSON.stringify({ text: "prompt fails" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: session.id })
    await waitFor(async () =>
      (await run(services.db.listSubjectEvents(session.id))).some(
        (event) => event.kind === "session.error"
      )
    )
    expect(agents.loads).toContainEqual(["codex", session.agentSessionId, workspaceFolder])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/connect`, {
          method: "POST"
        })
      ).body
    ).toMatchObject({
      configOptions: [
        {
          currentValue: "gpt-current",
          id: "model",
          options: [{ value: "gpt-current" }, { value: "gpt-new" }]
        }
      ],
      sessionId: session.agentSessionId
    })
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({ clientActionId: "cancel-retry-1" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/cancel`, {
          body: JSON.stringify({ clientActionId: "cancel-retry-1" }),
          method: "POST"
        })
      ).status
    ).toBe(202)
    expect(agents.cancellations).toEqual([session.agentSessionId])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mode`, {
          body: JSON.stringify({ modeId: "plan" }),
          method: "POST"
        })
      ).body
    ).toEqual({ modeId: "plan" })
    expect(agents.modes).toEqual([[session.agentSessionId, "plan"]])
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/config`, {
          body: JSON.stringify({ configId: "model", value: "gpt-5" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ configId: "model", configOptions: [{ id: "model" }] })
    expect(agents.configs).toEqual([[session.agentSessionId, "model", "gpt-5"]])

    // Goal set: the double-option tokenBudget key only forwards when present.
    const goalResponse = await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ clientActionId: "goal-1", objective: "ship it", tokenBudget: 50000 }),
      method: "POST"
    })
    expect(goalResponse.status).toBe(202)
    expect(goalResponse.body).toMatchObject({
      objective: "ship it",
      status: "active",
      tokenBudget: 50000
    })
    expect(agents.goals).toEqual([
      [session.agentSessionId, { objective: "ship it", tokenBudget: 50000 }]
    ])
    // Idempotent replay: the same clientActionId returns the stored result
    // without re-invoking the runtime.
    const goalReplay = await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ clientActionId: "goal-1", objective: "ship it", tokenBudget: 50000 }),
      method: "POST"
    })
    expect(goalReplay.status).toBe(202)
    expect(agents.goals).toHaveLength(1)
    // Pause keeps the budget key off the wire entirely.
    await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ status: "paused" }),
      method: "POST"
    })
    expect(agents.goals.at(-1)).toEqual([session.agentSessionId, { status: "paused" }])
    // Explicit null clears the budget.
    await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
      body: JSON.stringify({ tokenBudget: null }),
      method: "POST"
    })
    expect(agents.goals.at(-1)).toEqual([session.agentSessionId, { tokenBudget: null }])
    // Bad payloads are rejected before reaching the runtime.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
          body: JSON.stringify({ status: "someday" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    // Runtime failures (e.g. goals unsupported by the harness) surface as errors.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/goal`, {
          body: JSON.stringify({ objective: "goal fails" }),
          method: "POST"
        })
      ).status
    ).toBeGreaterThanOrEqual(400)
    // Clear.
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/goal`, { method: "DELETE" })).status
    ).toBe(204)
    expect(agents.goalClears).toEqual([session.agentSessionId])

    // Question answers route to the runtime, with idempotent replay.
    const answerBody = {
      answers: { approach: { answers: ["MVP first"], note: "keep it lean" } },
      clientActionId: "answer-1",
      outcome: "answered"
    }
    const answerResponse = await jsonRequest(
      server,
      `/v1/sessions/${session.id}/questions/q-1/answer`,
      {
        body: JSON.stringify(answerBody),
        method: "POST"
      }
    )
    expect(answerResponse.status).toBe(202)
    expect(answerResponse.body).toEqual({ outcome: "answered", questionId: "q-1" })
    await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-1/answer`, {
      body: JSON.stringify(answerBody),
      method: "POST"
    })
    expect(agents.questionAnswers).toEqual([
      [
        session.agentSessionId,
        "q-1",
        {
          answers: { approach: { answers: ["MVP first"], note: "keep it lean" } },
          outcome: "answered"
        }
      ]
    ])
    // Cancel outcome forwards without answers.
    await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-2/answer`, {
      body: JSON.stringify({ outcome: "cancelled" }),
      method: "POST"
    })
    expect(agents.questionAnswers.at(-1)).toEqual([
      session.agentSessionId,
      "q-2",
      { outcome: "cancelled" }
    ])
    // Bad payloads 400 before reaching the runtime; stale questions surface errors.
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/questions/q-3/answer`, {
          body: JSON.stringify({ outcome: "maybe" }),
          method: "POST"
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/questions/stale-question/answer`, {
          body: JSON.stringify({ outcome: "answered" }),
          method: "POST"
        })
      ).status
    ).toBeGreaterThanOrEqual(400)

    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ title: "Retitled" }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: false, title: "Retitled" })
    // Retitling never touches the runtime.
    expect(agents.closes).toEqual([])

    // Archiving retires the runtime: the agent session closes and its
    // background-task terminals (and only those) are killed and removed.
    const backgroundProcess = { killCount: 0 }
    const backgroundTerminal = services.terminal.registerExternalTerminal(
      { sessionId: `${session.agentSessionId}:bg:tool-1` },
      {
        kill: () => {
          backgroundProcess.killCount += 1
        },
        resize: () => undefined,
        write: () => undefined
      }
    )
    const unrelatedTerminal = services.terminal.registerExternalTerminal(
      { sessionId: "other-session:bg:tool-9" },
      { kill: () => undefined, resize: () => undefined, write: () => undefined }
    )
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}`, {
          body: JSON.stringify({ isArchived: true }),
          method: "PATCH"
        })
      ).body
    ).toMatchObject({ isArchived: true })
    expect(agents.closes).toEqual([session.agentSessionId])
    expect(backgroundProcess.killCount).toBe(1)
    await expect(
      run(services.terminal.terminalFrames(backgroundTerminal.terminalId))
    ).rejects.toBeInstanceOf(TerminalError)
    expect(await run(services.terminal.terminalFrames(unrelatedTerminal.terminalId))).toEqual([])

    // A session with no runtime identity archives without touching the runtime.
    const runtimelessSession = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          agentSessionId: "",
          harnessId: "codex",
          projectId: workspace.id,
          title: "Imported"
        }),
        method: "POST"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, `/v1/sessions/${runtimelessSession.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(agents.closes).toEqual([session.agentSessionId])
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}`, { method: "DELETE" })).status
    ).toBe(204)
    expect(
      (await jsonRequest(server, `/v1/projects/${workspace.id}`, { method: "DELETE" })).status
    ).toBe(204)

    expect((await readSseEvents(server, 1)).at(0)).toEqual(
      expect.objectContaining({ kind: "project.created" })
    )
    expect((await readSseEvents(server, 1, "not-a-number")).at(0)).toEqual(
      expect.objectContaining({ kind: "project.created" })
    )
    const replayEvents = await run(services.db.listEvents(0))
    const replayEventCount = replayEvents.length
    const replayCursor = replayEvents.at(-1)?.id ?? 0
    const events = await readSseEvents(server, replayEventCount, 0)
    expect(events).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ kind: "project.created" }),
        expect.objectContaining({ kind: "project.deleted" }),
        expect.objectContaining({ kind: "session.created" }),
        expect.objectContaining({ kind: "session.deleted" })
      ])
    )

    const liveEvent = readSseEvents(server, 1, replayCursor)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/live" }),
      method: "POST"
    })
    expect(await liveEvent).toEqual([expect.objectContaining({ kind: "project.created" })])
    const websocketReplay = await readWebSocketEvents(server, 2, 0)
    expect(websocketReplay).toEqual([
      expect.objectContaining({ kind: "project.created" }),
      expect.objectContaining({ kind: "project.updated" })
    ])
    const socketReplayEvents = await run(services.db.listEvents(0))
    const socketReplayCursor = socketReplayEvents.at(-1)?.id ?? 0
    const websocketLive = readWebSocketEvents(server, 1, socketReplayCursor)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/live-socket" }),
      method: "POST"
    })
    expect(await websocketLive).toEqual([expect.objectContaining({ kind: "project.created" })])

    const legacyWorkspace = await run(
      services.db.createProject({ folderPath: legacyWorkspaceFolder })
    )
    const legacySession = await run(
      services.db.createSession({
        harnessId: "codex",
        id: "legacy-session",
        title: "Legacy session",
        projectId: legacyWorkspace.id
      })
    )
    expect(legacySession.agentSessionId).toBeUndefined()
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${legacySession.id}/prompt`, {
          body: JSON.stringify({ text: "legacy hello" }),
          method: "POST"
        })
      ).body
    ).toMatchObject({ accepted: true, sessionId: legacySession.id })
    await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "legacy hello"))
    expect(agents.prompts).toContainEqual([legacySession.id, "legacy hello"])
    expect(agents.loads).toContainEqual(["codex", legacySession.id, legacyWorkspaceFolder])
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

  it("deduplicates concurrent client session creation while creation is pending", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-pending-create-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder, id: "pending-create-project" }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const sessionBody = JSON.stringify({
      id: "client-session-pending-create",
      projectId: project.id,
      harnessId: "codex",
      title: "Pending create"
    })
    const [first, second] = await Promise.all([
      jsonRequest(server, "/v1/sessions", {
        body: sessionBody,
        method: "POST"
      }),
      jsonRequest(server, "/v1/sessions", {
        body: sessionBody,
        method: "POST"
      })
    ])
    expect([first.status, second.status].sort()).toEqual([200, 201])
    expect(first.body).toEqual(second.body)
    expect(agents.creations).toEqual([["codex", workspaceFolder]])
  })

  it("opens a session in one round-trip, creating project and session only when missing", async () => {
    const { agents, server, services } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-open-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)

    // First open: nothing exists server-side — both records are created and
    // the first transcript page comes back, all in one request.
    const opened = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        project: { folderPath: workspaceFolder, id: "open-project-1" },
        session: {
          harnessId: "codex",
          id: "open-session-1",
          projectId: "open-project-1",
          title: "Open flow"
        },
        transcriptLimit: 8
      }),
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect(opened.body).toMatchObject({
      session: { id: "open-session-1", projectId: "open-project-1", title: "Open flow" },
      transcript: { hasMore: false, items: [], pendingPlanApproval: false }
    })
    expect(agents.creations).toEqual([["codex", workspaceFolder]])

    await run(
      services.db.appendEvent("session.output", "open-session-1", {
        sessionUpdate: "plan",
        entries: [{ content: "Implement", priority: "medium", status: "in_progress" }]
      })
    )

    const unchanged = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        session: { harnessId: "codex", projectId: "open-project-1" }
      }),
      method: "POST"
    })
    expect(unchanged.status).toBe(200)
    expect(unchanged.body).toMatchObject({
      session: { title: "Open flow" },
      transcript: {
        sessionPlan: {
          entries: [{ content: "Implement", priority: "medium", status: "in_progress" }]
        }
      }
    })

    // Archive the project, then re-open with the original (now stale)
    // snapshot: the existing project must NOT be reverted to unarchived, the
    // session must not be re-created, and the update payload applies.
    await jsonRequest(server, "/v1/projects/open-project-1", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    const reopened = await jsonRequest(server, "/v1/sessions/open-session-1/open", {
      body: JSON.stringify({
        project: { folderPath: workspaceFolder, id: "open-project-1" },
        session: {
          harnessId: "codex",
          id: "open-session-1",
          projectId: "open-project-1",
          title: "Open flow"
        },
        update: { title: "Renamed on open" }
      }),
      method: "POST"
    })
    expect(reopened.status).toBe(200)
    expect(reopened.body).toMatchObject({ session: { title: "Renamed on open" } })
    expect(agents.creations).toHaveLength(1)
    const projects = (await jsonRequest(server, "/v1/projects")).body as ReadonlyArray<{
      readonly id: string
      readonly isArchived: boolean
    }>
    expect(projects.find((candidate) => candidate.id === "open-project-1")?.isArchived).toBe(true)

    // A body/path session-id mismatch is rejected before any writes.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/other-id/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", id: "open-session-1", projectId: "open-project-1" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    // Invalid transcript limits are rejected before any writes.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/open-session-1/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", projectId: "open-project-1" },
            transcriptLimit: 0
          }),
          method: "POST"
        })
      ).status
    ).toBe(400)

    // An open naming an unknown project with no project payload still 404s.
    expect(
      (
        await jsonRequest(server, "/v1/sessions/orphan-session/open", {
          body: JSON.stringify({
            session: { harnessId: "codex", id: "orphan-session", projectId: "missing-project" }
          }),
          method: "POST"
        })
      ).status
    ).toBe(404)
  })

  it("treats differently-cased session ids as one session instead of minting a case-twin", async () => {
    const { server } = await start()
    const projectRoot = mkdtempSync(join(tmpdir(), "codevisor-server-case-"))
    tempDirs.push(projectRoot)
    const workspaceFolder = join(projectRoot, "workspace")
    mkdirSync(workspaceFolder)

    // A chat created by a Node client stores the canonical lowercase uuid.
    const lowerId = "ab12cd34-ef56-4789-a012-3456789abcde"
    const upperId = lowerId.toUpperCase()
    const project = (
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: workspaceFolder, id: "case-project" }),
        method: "POST"
      })
    ).body as { readonly id: string }
    const created = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        id: lowerId,
        projectId: project.id,
        harnessId: "codex",
        title: "Created remotely"
      }),
      method: "POST"
    })
    expect(created.status).toBe(201)

    // Opening it with Swift's uppercase rendering must return the existing
    // row — this exact path used to insert a case-twin duplicate session,
    // which every client then showed as a second sidebar entry.
    const opened = await jsonRequest(server, `/v1/sessions/${upperId}/open`, {
      body: JSON.stringify({
        session: {
          harnessId: "codex",
          id: upperId,
          projectId: project.id.toUpperCase(),
          title: "Created remotely"
        }
      }),
      method: "POST"
    })
    expect(opened.status).toBe(200)
    expect(opened.body).toMatchObject({ session: { id: lowerId, title: "Created remotely" } })

    // Updates addressed with the uppercase id land on the same single row.
    const renamed = await jsonRequest(server, `/v1/sessions/${upperId}`, {
      body: JSON.stringify({ title: "Renamed from the Mac" }),
      method: "PATCH"
    })
    expect(renamed.status).toBe(200)
    const sessions = (await jsonRequest(server, "/v1/sessions")).body as ReadonlyArray<{
      readonly id: string
      readonly title: string
    }>
    const twins = sessions.filter((session) => session.id.toLowerCase() === lowerId)
    expect(twins).toHaveLength(1)
    expect(twins[0]).toMatchObject({ id: lowerId, title: "Renamed from the Mac" })
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
