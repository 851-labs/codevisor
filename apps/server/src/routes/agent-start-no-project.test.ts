import { existsSync, mkdtempSync, readdirSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { decode, StartedAgent } from "@codevisor/api"
import { DatabaseError, scratchWorkspacesRoot } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"
import { idOf } from "./response-test-support.js"

afterEach(() => {
  vi.restoreAllMocks()
  delete process.env["CODEVISOR_WORKTREES_ROOT"]
})

const machine = async () => {
  process.env["CODEVISOR_WORKTREES_ROOT"] = mkdtempSync(join(tmpdir(), "codevisor-no-project-"))
  tempDirs.push(process.env["CODEVISOR_WORKTREES_ROOT"])
  const running = await start()
  const startAgent = (fields: Record<string, unknown>) =>
    jsonRequest(running.server, "/v1/agents", {
      body: JSON.stringify({
        prompt: "Try it",
        title: "Scratch",
        isolation: "worktree",
        ...fields
      }),
      method: "POST"
    })
  return { ...running, startAgent }
}

const scratchFolders = (): ReadonlyArray<string> =>
  existsSync(scratchWorkspacesRoot()) ? readdirSync(scratchWorkspacesRoot()) : []

const callerIn = async (server: Awaited<ReturnType<typeof machine>>["server"]) => {
  const folder = mkdtempSync(join(tmpdir(), "codevisor-no-project-caller-"))
  tempDirs.push(folder)
  await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: folder, id: "caller-project", name: "Caller" }),
    method: "POST"
  })
  const created = await jsonRequest(server, "/v1/sessions", {
    body: JSON.stringify({ projectId: "caller-project", harnessId: "codex" }),
    method: "POST"
  })
  return idOf(created.body)
}

describe("POST /v1/agents with noProject", () => {
  it("starts in a fresh empty folder, in a new workspace under its caller", async () => {
    const { agents, server, services, startAgent } = await machine()
    const caller = await callerIn(server)

    const response = await startAgent({ callerAgentId: caller, noProject: true })

    expect(response.status).toBe(201)
    const started = decode(StartedAgent)(response.body)
    expect(started).toMatchObject({ subscribed: true, workspaceId: expect.any(String) })
    expect(started.worktreeName).toBeUndefined()
    const scratch = (await run(services.db.listProjects)).find(
      (project) => project.id === started.projectId
    )
    expect(scratch).toMatchObject({ isScratch: true })
    const folder = scratch!.locations[0]!.folderPath
    expect(readdirSync(folder)).toEqual([])
    expect(await run(services.db.getSessionSummary(started.agentId))).toMatchObject({
      parentSessionId: caller,
      cwd: folder
    })
    await waitFor(() => agents.prompts.some(([, text]) => text === "Try it"))
  })

  it("gives each start its own folder and doesn't clone the caller's project from another machine", async () => {
    const { services, startAgent } = await machine()
    const remote = {
      noProject: true,
      callerDefaults: {
        harness: "codex",
        project: { name: "widget", repoUrl: "file:///nowhere/widget.git" }
      }
    }

    const first = decode(StartedAgent)((await startAgent(remote)).body)
    const second = decode(StartedAgent)((await startAgent(remote)).body)

    expect(first.projectId).not.toBe(second.projectId)
    const projects = await run(services.db.listProjects)
    expect(projects.map((project) => project.isScratch)).toEqual([true, true])
  })

  it("removes the folder and project it made when the chat can't be created", async () => {
    const { services, startAgent } = await machine()
    vi.spyOn(services.db, "createWorkspaceWithSession").mockReturnValueOnce(
      Effect.fail(
        new DatabaseError({ operation: "createWorkspaceWithSession", message: "database locked" })
      )
    )

    const response = await startAgent({ harness: "codex", noProject: true })

    expect(JSON.stringify(response.body)).toContain("database locked")
    expect(await run(services.db.listProjects)).toEqual([])
    expect(scratchFolders()).toEqual([])
  })

  it("refuses a project or sandbox profile alongside noProject before making a folder", async () => {
    const { startAgent } = await machine()

    const withProject = await startAgent({ harness: "codex", noProject: true, project: "x" })
    const withSandbox = await startAgent({ harness: "codex", noProject: true, sandboxProfile: "x" })

    expect(withProject).toMatchObject({
      status: 422,
      body: { error: expect.stringContaining("not both") }
    })
    expect(withSandbox).toMatchObject({
      status: 422,
      body: { error: expect.stringContaining("sandbox") }
    })
    expect(scratchFolders()).toEqual([])
  })

  it("offers noProject when the project is missing, listing only sidebar projects", async () => {
    const { startAgent } = await machine()
    await startAgent({ harness: "codex", noProject: true })

    const response = await startAgent({ harness: "codex" })

    expect(response.body).toMatchObject({
      error: expect.stringMatching(/noProject: true.*Projects on this machine: none$/)
    })
  })
})
