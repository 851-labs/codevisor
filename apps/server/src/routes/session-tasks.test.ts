import type { SessionSummary } from "@codevisor/api"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, makeServices, run, startWithApp } from "../test-support.js"

const liveAgent = "agent-live"

const startTaskRoutes = async () => {
  const { services } = await makeServices("server-a")
  const project = await run(services.db.createProject({ folderPath: "/tmp" }))
  const session = await run(
    services.db.createSession({ projectId: project.id, harnessId: "claude-code" })
  )
  const stopped: Array<string> = []
  let projected: SessionSummary = { ...session, agentSessionId: liveAgent }
  const server = await startWithApp({
    ...services,
    agents: {
      ...services.agents,
      loadedAgentSessionIds: () => [liveAgent],
      stopTask: (_agentSessionId: string, taskId: string) =>
        Effect.sync(() => {
          stopped.push(taskId)
          return taskId !== "unstoppable"
        }),
      readTaskOutput: (_agentSessionId: string, taskId: string, lineLimit: number) =>
        Effect.succeed(taskId === "bg-1" ? [`last ${lineLimit} lines`] : undefined)
    },
    db: {
      ...services.db,
      getSessionSummary: (id: string) =>
        id === session.id ? Effect.succeed(projected) : services.db.getSessionSummary(id)
    }
  })
  const projectSession = (next: SessionSummary) => {
    projected = next
  }
  return { server, session, stopped, projectSession }
}

const post = (server: Awaited<ReturnType<typeof startWithApp>>, path: string) =>
  jsonRequest(server, path, { method: "POST" })

describe("session task routes", () => {
  it("stops a single task of a running agent", async () => {
    const { server, session, stopped } = await startTaskRoutes()

    expect((await post(server, `/v1/sessions/${session.id}/tasks/bg-1/stop`)).status).toBe(204)
    expect(stopped).toEqual(["bg-1"])
    expect((await post(server, `/v1/sessions/${session.id}/tasks/unstoppable/stop`)).status).toBe(
      409
    )
  })

  it("reads the last lines of a task's output, or 404 when the harness has none", async () => {
    const { server, session } = await startTaskRoutes()

    expect(await jsonRequest(server, `/v1/sessions/${session.id}/tasks/bg-1/output`)).toEqual({
      body: { lines: ["last 50 lines"] },
      status: 200
    })
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/tasks/bg-2/output`)).status).toBe(
      404
    )
  })

  it("refuses tasks of a missing session or an agent that isn't running", async () => {
    const { server, session, projectSession } = await startTaskRoutes()

    expect((await post(server, "/v1/sessions/missing/tasks/bg-1/stop")).status).toBe(404)
    projectSession({ ...session, agentSessionId: "agent-idle" })
    expect((await post(server, `/v1/sessions/${session.id}/tasks/bg-1/stop`)).status).toBe(409)
    expect((await jsonRequest(server, `/v1/sessions/${session.id}/tasks/bg-1/output`)).status).toBe(
      409
    )
  })
})
