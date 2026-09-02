import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import {
  defaultServerConfig,
  makeEventFanout,
  reconcileOrphanedSessionTurns,
  startCodevisorServer
} from "../server.js"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs
} from "../test-support.js"

describe("durable session turns", () => {
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
})
