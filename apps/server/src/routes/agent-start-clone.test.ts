import { join } from "node:path"

import { decode, StartedAgent } from "@codevisor/api"
import { afterEach, describe, expect, it } from "vitest"

import { jsonRequest, listSubjectEvents, run, start, waitFor } from "../test-support.js"
import { makeOrigin, tempDir, useBaseFolder } from "./project-setup-test-support.js"

afterEach(() => {
  delete process.env["CODEVISOR_WORKTREES_ROOT"]
})

const machineWithoutProject = async () => {
  process.env["CODEVISOR_WORKTREES_ROOT"] = tempDir("codevisor-clone-start-trees-")
  const running = await start()
  const baseFolder = await useBaseFolder(running.server)
  const origin = await makeOrigin()
  const startRemoteAgent = async (fields: Record<string, unknown>) =>
    jsonRequest(running.server, "/v1/agents", {
      body: JSON.stringify({
        prompt: "Fix it",
        title: "Fix login",
        isolation: "worktree",
        project: "id-on-the-caller-machine",
        callerDefaults: {
          harness: "codex",
          project: { name: "widget", repoUrl: `file://${origin}` }
        },
        ...fields
      }),
      method: "POST"
    })
  return { ...running, baseFolder, startRemoteAgent }
}

describe("POST /v1/agents on a machine without the project", () => {
  it("clones the caller's project first, then starts the agent in a new worktree", async () => {
    const { agents, services, baseFolder, startRemoteAgent } = await machineWithoutProject()

    const response = await startRemoteAgent({})

    expect(response.status).toBe(201)
    const started = decode(StartedAgent)(response.body)
    expect(started.worktreeName).toEqual(expect.any(String))
    const projects = await run(services.db.listProjects)
    expect(projects).toEqual([
      expect.objectContaining({
        id: started.projectId,
        name: "widget",
        locations: [expect.objectContaining({ folderPath: join(baseFolder, "widget") })]
      })
    ])
    expect(listSubjectEvents(services, started.projectId).at(-1)).toMatchObject({
      kind: "project.created"
    })
    await waitFor(() => agents.prompts.some(([, text]) => text === "Fix it"))
  })

  it("reuses the clone on the next start", async () => {
    const { services, startRemoteAgent } = await machineWithoutProject()

    const first = decode(StartedAgent)((await startRemoteAgent({})).body)
    const second = decode(StartedAgent)((await startRemoteAgent({ isolation: "project" })).body)

    expect(second.projectId).toBe(first.projectId)
    expect(await run(services.db.listProjects)).toHaveLength(1)
  })

  it("reports the clone failure when the repository can't be reached", async () => {
    const { services, startRemoteAgent } = await machineWithoutProject()

    const response = await startRemoteAgent({
      callerDefaults: {
        harness: "codex",
        project: { name: "gone", repoUrl: "file:///nowhere/gone.git" }
      }
    })

    expect(response.status).toBeGreaterThanOrEqual(400)
    expect(await run(services.db.listProjects)).toEqual([])
    expect(await run(services.db.listSessions)).toEqual([])
  })
})
