import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { AgentStatus, decode, StartedAgent } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"
import { idOf } from "./response-test-support.js"

const shell = { id: "task-1", description: "npm test", status: "running", taskType: "shell" }

const addProject = async (running: Awaited<ReturnType<typeof start>>, id: string) => {
  const folder = mkdtempSync(join(tmpdir(), "codevisor-start-events-"))
  tempDirs.push(folder)
  await jsonRequest(running.server, "/v1/projects", {
    body: JSON.stringify({ folderPath: folder, id }),
    method: "POST"
  })
}

const startedFromParent = async (prompt: string) => {
  const running = await start()
  await addProject(running, "parent-project")
  await addProject(running, "events-project")
  const parent = idOf(
    (
      await jsonRequest(running.server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "parent-project", harnessId: "codex" }),
        method: "POST"
      })
    ).body
  )
  const started = decode(StartedAgent)(
    (
      await jsonRequest(running.server, "/v1/agents", {
        body: JSON.stringify({
          prompt,
          title: "Fix login",
          isolation: "project",
          project: "events-project",
          callerAgentId: parent
        }),
        method: "POST"
      })
    ).body
  )
  const { agentSessionId } = await run(running.services.db.getSessionSummary(started.agentId))
  const parentEvents = () =>
    running.agents.prompts.flatMap(([, input]) =>
      typeof input === "string" && input.startsWith("<codevisor-event") ? [input] : []
    )
  const status = async () =>
    decode(AgentStatus)((await jsonRequest(running.server, `/v1/agents/${started.agentId}`)).body)
      .state
  const emit = (kind: "session.updated" | "session.output", payload: Record<string, unknown>) =>
    running.agents.emit(agentSessionId!, { kind, subjectId: agentSessionId!, payload })
  return { ...running, parent, agentId: started.agentId, parentEvents, status, emit }
}

describe("events from an agent started with agents.start", () => {
  it("tells the parent when its agent's turn ends, and reads the agent as idle", async () => {
    const child = await startedFromParent("Fix it")

    await waitFor(() => child.parentEvents().length === 1)

    expect(child.parentEvents()[0]).toContain(
      `<codevisor-event type="session.turn_ended" agentId="${child.agentId}" title="Fix login" stopReason="end_turn"`
    )
    expect(child.parentEvents()[0]).toContain("\nEcho: Fix it\n")
    expect(await child.status()).toBe("idle")
  })

  it("tells the parent when its agent asks a question", async () => {
    const child = await startedFromParent("prompt until cancelled")
    await waitFor(async () => (await child.status()) === "working")

    await child.emit("session.output", {
      sessionUpdate: "question",
      questionId: "q1",
      questions: [
        { id: "go", question: "Ship it?", options: [{ label: "Yes" }], allowsOther: false }
      ]
    })
    await waitFor(() => child.parentEvents().length === 1)

    expect(child.parentEvents()[0]).toContain(
      `<codevisor-event type="session.waiting_for_user" agentId="${child.agentId}" title="Fix login" kind="question"`
    )
    expect(await child.status()).toBe("waitingForUser")
  })

  it("tells the parent when its agent errors", async () => {
    const child = await startedFromParent("prompt fails")

    await waitFor(() => child.parentEvents().length === 1)

    expect(child.parentEvents()[0]).toContain(
      `<codevisor-event type="session.errored" agentId="${child.agentId}" title="Fix login"`
    )
    expect(await child.status()).toBe("errored")
  })

  it("reads an agent as working while its turn end waits on background work", async () => {
    const child = await startedFromParent("Fix it")
    await waitFor(() => child.parentEvents().length === 1)

    await child.emit("session.updated", { backgroundTasks: [shell] })
    await child.emit("session.updated", {
      initiatedBy: "agent",
      turnId: "t-2",
      turnState: "started"
    })
    await child.emit("session.output", { role: "assistant", text: "Waiting on the tests" })
    await child.emit("session.updated", {
      initiatedBy: "agent",
      stopReason: "end_turn",
      turnId: "t-2",
      turnState: "ended"
    })

    await waitFor(async () => (await child.status()) === "working")
    expect(child.parentEvents()).toHaveLength(1)
  })
})
