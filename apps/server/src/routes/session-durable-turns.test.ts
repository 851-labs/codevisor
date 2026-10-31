import { randomUUID } from "node:crypto"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { describe, expect, it, vi } from "vitest"

import { queueRestartResumeOnce, restartNotice } from "../restart-notice.js"
import { defaultServerConfig, makeEventFanout, startCodevisorServer } from "../server.js"
import {
  archiveSessionViaWorkspace,
  jsonRequest,
  makeServices,
  run,
  runningServers,
  startWithApp,
  tempDirs,
  listSubjectEvents,
  waitFor
} from "../test-support.js"
import { reconcileOrphanedSessionTurns } from "./prompt-recovery.js"

const isQuestionResolution = (payload: unknown): boolean =>
  typeof payload === "object" &&
  payload !== null &&
  "sessionUpdate" in payload &&
  payload.sessionUpdate === "question_resolved"

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
    await archiveSessionViaWorkspace(services, project.id, archived.id)
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

    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0 })
      )
    )
    runningServers.push(server)

    expect(agents.loads).toEqual([])
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.pendingQuestion?.questionId).toBe("orphaned-question")
    expect(
      (await run(services.db.getTranscriptPage(archived.id, undefined, 8))).items.at(-1)
    ).toMatchObject({ isGenerating: false, stopReason: "end_turn" })
    const splitPage = await run(services.db.getTranscriptPage(splitBrain.id, undefined, 8))
    expect(splitPage.items.map((item) => item.isGenerating)).toEqual([false, false])
    expect(splitPage.items.at(0)).toMatchObject({
      role: "assistant",
      isGenerating: false,
      stopReason: "end_turn"
    })
    expect(splitPage.items.at(0)).not.toHaveProperty("stopDetail")
    expect(page.items.at(-1)).toMatchObject({
      isGenerating: false,
      stopReason: "end_turn",
      stopKind: "interrupted"
    })
    expect(page.items.at(-1)).not.toHaveProperty("stopDetail")
    const events = listSubjectEvents(services, session.id)
    expect(events.map((event) => event.payload).filter(isQuestionResolution)).toEqual([])
    expect(events.map((event) => event.payload)).toContainEqual(
      expect.objectContaining({
        stopReason: "end_turn",
        turnId: "orphaned-turn",
        turnState: "ended"
      })
    )

    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(200)
    expect(agents.loads).toEqual([["codex", "agent-before-crash", folder]])
  })

  it("tells agents whose background tasks died in a crash, once, ahead of their queued prompts", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-recovery-tasks-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const seedSession = async (agentSessionId: string, description: string) => {
      const session = await run(
        services.db.createSession({ projectId: project.id, harnessId: "codex", agentSessionId })
      )
      await run(
        services.db.appendEvent("session.updated", session.id, {
          backgroundTasks: [
            { id: `${agentSessionId}-task`, description, status: "running", taskType: "shell" }
          ]
        })
      )
      return session
    }
    const midTurn = await seedSession("agent-mid-turn", "Run   the\nchecks")
    await run(
      services.db.appendEvent("session.updated", midTurn.id, {
        initiatedBy: "user",
        turnId: "crashed-turn",
        turnState: "started"
      })
    )
    await run(services.db.createPromptQueueItem(midTurn.id, "queued earlier"))
    const waiting = await seedSession("agent-waiting", "Monitor the deploy")
    const recrashed = await seedSession("agent-recrashed", "Watch the logs")
    await queueRestartResumeOnce(services, recrashed.id, restartNotice(["Watch the logs"]))
    const archived = await seedSession("agent-archived", "Build the app")
    await archiveSessionViaWorkspace(services, project.id, archived.id)

    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0 })
      )
    )
    runningServers.push(server)

    await waitFor(() => agents.prompts.length === 4)
    expect(agents.prompts.filter(([agent]) => agent === "agent-recrashed")).toEqual([
      ["agent-recrashed", restartNotice(["Watch the logs"])]
    ])
    expect(agents.prompts.filter(([agent]) => agent === "agent-mid-turn")).toEqual([
      ["agent-mid-turn", restartNotice(["Run the checks"])],
      ["agent-mid-turn", "queued earlier"]
    ])
    expect(agents.prompts).toContainEqual(["agent-waiting", restartNotice(["Monitor the deploy"])])
    expect(await run(services.db.listPromptQueue(archived.id))).toEqual([])
    for (const session of [midTurn, waiting, recrashed, archived]) {
      const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
      expect(page.backgroundTasks).toEqual([])
    }
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
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0 })
      )
    )
    runningServers.push(server)

    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.items).toMatchObject([
      { role: "user", text: "do not lose me", isGenerating: false },
      { role: "assistant", stopReason: "end_turn", isGenerating: false }
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
      { role: "assistant", stopReason: "end_turn" }
    ])
    expect(await run(services.db.listProcessingPromptQueue(dispatchedSession.id))).toEqual([])
    expect(await run(services.db.listProcessingPromptQueue(attachedMissingSession.id))).toEqual([])

    const before = listSubjectEvents(services, session.id)
    await reconcileOrphanedSessionTurns(services, await run(makeEventFanout), "server-a")
    expect(listSubjectEvents(services, session.id)).toHaveLength(before.length)
  })

  it("cancels a setup prompt left waiting when the server restarts", async () => {
    const { services } = await makeServices("server-a")
    const folder = mkdtempSync(join(tmpdir(), "codevisor-setup-recovery-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder }))
    const session = await run(
      services.db.createSession({
        projectId: project.id,
        harnessId: "codex",
        agentSessionId: "agent"
      })
    )
    await run(
      services.db.appendEvent("session.updated", session.id, {
        turnId: "waiting-turn",
        turnState: "started"
      })
    )
    await run(
      services.db.appendEvent("session.output", session.id, {
        sessionUpdate: "question",
        questionId: "computer-use",
        questions: [
          {
            id: "computer_use_permissions",
            question: "Allow",
            options: [{ label: "Continue" }],
            allowsOther: false,
            presentation: "computerUsePermissions"
          }
        ]
      })
    )

    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0 })
      )
    )
    runningServers.push(server)

    const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
    expect(page.pendingQuestion).toBeUndefined()
    expect(page.items.flatMap((item) => item.setupRequests ?? [])).toEqual([
      { questionId: "computer-use", presentation: "computerUsePermissions", outcome: "cancelled" }
    ])
    expect(
      listSubjectEvents(services, session.id).some((event) => isQuestionResolution(event.payload))
    ).toBe(true)
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
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "server-a", port: 0 })
      )
    )
    runningServers.push(server)

    expect(agents.loads).toEqual([])
    expect(await run(services.db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      items: [{ isGenerating: false, stopReason: "end_turn" }]
    })
    expect(
      (await jsonRequest(server, `/v1/sessions/${session.id}/connect`, { method: "POST" })).status
    ).toBe(400)
    expect(agents.loads).toEqual([])
  })
})
