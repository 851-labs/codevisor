import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, Project } from "@codevisor/api"
import { Effect, Schema } from "effect"
import { describe, expect, it } from "vitest"

import {
  jsonRequest,
  makeServices,
  start,
  startWithApp,
  tempDirs,
  listSubjectEvents
} from "../test-support.js"
import { resetRepoUrlDiscoveryCache } from "./project-repo-identity.js"
import { isDeletableProjectFolder } from "./projects.js"
import { field, idOf, itemsOf } from "./response-test-support.js"

const execFileAsync = promisify(execFile)
const decodeProject = decode(Project)

const runGit = (args: ReadonlyArray<string>, cwd: string) =>
  execFileAsync("git", [...args], { cwd })

describe("project routes", () => {
  it("returns machine-local project recommendations from installed harness sessions", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(homedir(), ".codevisor-project-route-recommendation-"))
    tempDirs.push(folder)
    const server = await startWithApp({
      ...services,
      agents: {
        ...agents,
        listAgentSessions: () =>
          Effect.succeed([
            {
              sessionId: "native-one",
              cwd: folder,
              updatedAt: "2026-08-27T12:00:00Z"
            },
            {
              sessionId: "native-two",
              cwd: folder,
              updatedAt: "2026-08-27T13:00:00Z"
            }
          ])
      }
    })

    const response = await jsonRequest(server, "/v1/projects/recommendations?limit=1")

    expect(response.status).toBe(200)
    expect(response.body).toEqual([
      {
        path: folder,
        name: folder.split("/").at(-1),
        sessionCount: 2,
        lastActivity: "2026-08-27T13:00:00Z"
      }
    ])

    const defaultLimit = await jsonRequest(server, "/v1/projects/recommendations")
    const invalidLimit = await jsonRequest(server, "/v1/projects/recommendations?limit=invalid")
    expect(defaultLimit.body).toEqual(response.body)
    expect(invalidLimit.body).toEqual(response.body)
  })

  it("serves repeat project recommendations from one title-free scan", async () => {
    const { agents, services } = await makeServices("server-a")
    const folder = mkdtempSync(join(homedir(), ".codevisor-project-route-recommendation-"))
    tempDirs.push(folder)
    const listOptions: Array<unknown> = []
    const server = await startWithApp({
      ...services,
      agents: {
        ...agents,
        listAgentSessions: (_harnessId, _account, options) => {
          listOptions.push(options)
          return Effect.succeed([{ sessionId: "native-one", cwd: folder }])
        }
      }
    })

    const first = await jsonRequest(server, "/v1/projects/recommendations")
    const scans = listOptions.length
    const second = await jsonRequest(server, "/v1/projects/recommendations")

    expect(second.body).toEqual(first.body)
    expect(scans).toBeGreaterThan(0)
    expect(listOptions).toHaveLength(scans)
    expect(listOptions.every((options) => field(options, "titles") === false)).toBe(true)
  })

  it("keeps unavailable harness stores from breaking project recommendations", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp({
      ...services,
      agents: {
        ...agents,
        listAgentSessions: () => Effect.die(new Error("native store unavailable"))
      }
    })

    const response = await jsonRequest(server, "/v1/projects/recommendations")

    expect(response.status).toBe(200)
    expect(response.body).toEqual([])
  })

  it("clones a git remote into the managed repos dir as a project", async () => {
    const reposRoot = mkdtempSync(join(tmpdir(), "codevisor-repos-"))
    tempDirs.push(reposRoot)
    process.env["CODEVISOR_REPOS_ROOT"] = reposRoot
    try {
      const { server, services } = await start()
      const origin = mkdtempSync(join(tmpdir(), "codevisor-origin-"))
      tempDirs.push(origin)
      const originRepo = join(origin, "widget.git")
      mkdirSync(originRepo)
      await runGit(["init"], originRepo)
      writeFileSync(join(originRepo, "README.md"), "hello")
      await runGit(["add", "."], originRepo)
      await runGit(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"],
        originRepo
      )

      const url = `file://${originRepo}`
      const created = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "cloned-project", url }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      expect(created.body).toMatchObject({
        id: "cloned-project",
        name: "widget",
        repoUrl: url,
        locations: [{ folderPath: join(reposRoot, "widget"), isGitRepository: true }]
      })
      expect(existsSync(join(reposRoot, "widget", "README.md"))).toBe(true)

      const events = listSubjectEvents(services, "cloned-project")
      const states = events
        .filter((event) => event.kind === "project.setup")
        .map((event) => field(event.payload, "state"))
      expect(states[0]).toBe("started")
      expect(states.at(-1)).toBe("completed")

      const invalid = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "not a url" }),
        method: "POST"
      })
      expect(invalid.status).toBe(400)
      expect(invalid.body).toMatchObject({ code: "invalid_url" })

      const unnameable = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "git@example.com:acme/--.git" }),
        method: "POST"
      })
      expect(unnameable.status).toBe(400)
      expect(field(unnameable.body, "error")).toContain("name")

      const missing = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "missing-project", url: `file://${origin}/gone.git` }),
        method: "POST"
      })
      expect(missing.status).toBe(422)
      expect(field(missing.body, "code")).toBeDefined()
      expect(existsSync(join(reposRoot, "gone"))).toBe(false)
      const failedEvents = listSubjectEvents(services, "missing-project")
      expect(
        failedEvents.some(
          (event) => event.kind === "project.setup" && field(event.payload, "state") === "failed"
        )
      ).toBe(true)
    } finally {
      delete process.env["CODEVISOR_REPOS_ROOT"]
    }
  })

  it("publishes a project rename to every client", async () => {
    const { server, services } = await start()
    const folderPath = mkdtempSync(join(tmpdir(), "codevisor-rename-project-"))
    tempDirs.push(folderPath)
    const projectId = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath }),
          method: "POST"
        })
      ).body
    )

    const renamed = await jsonRequest(server, `/v1/projects/${projectId}`, {
      body: JSON.stringify({ name: "Renamed" }),
      method: "PATCH"
    })

    expect(renamed).toMatchObject({ status: 200, body: { id: projectId, name: "Renamed" } })
    expect(listSubjectEvents(services, projectId).at(-1)).toMatchObject({
      kind: "project.updated",
      payload: { id: projectId, name: "Renamed" }
    })
  })

  it("addresses projects by id case-insensitively", async () => {
    const { server } = await start()
    const lowerId = "0d604f39-364b-4a17-8fd8-21bddd8c1399"
    const upperId = lowerId.toUpperCase()

    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect(idOf(created.body)).toBe(lowerId)

    const resync = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect(idOf(resync.body)).toBe(lowerId)
    expect(itemsOf((await jsonRequest(server, "/v1/projects")).body).length).toBe(1)

    const session = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: upperId, harnessId: "codex" }),
      method: "POST"
    })
    expect(session.status).not.toBe(404)
    expect(JSON.stringify(session.body)).not.toContain("Project not found")

    const worktree = await jsonRequest(server, `/v1/projects/${upperId}/worktrees`, {
      body: JSON.stringify({ name: "feature" }),
      method: "POST"
    })
    expect(worktree.status).not.toBe(404)
    expect(JSON.stringify(worktree.body)).not.toContain("Project not found")
  })

  it("deletes a project's folder only when asked, and never one holding Codevisor's own files", async () => {
    const base = mkdtempSync(join(tmpdir(), "codevisor-delete-files-"))
    tempDirs.push(base)
    process.env["CODEVISOR_WORKTREES_ROOT"] = join(base, "codevisor")
    try {
      const { server } = await start()
      const folder = (name: string): string => {
        const path = join(base, name)
        mkdirSync(join(path, "src"), { recursive: true })
        writeFileSync(join(path, "src", "index.ts"), "x")
        return path
      }
      const create = async (id: string, folderPath: string): Promise<void> => {
        const response = await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({ folderPath, id }),
          method: "POST"
        })
        expect(response.status).toBe(201)
      }
      const kept = folder("kept")
      const removed = folder("removed")
      await create("kept-project", kept)
      await create("removed-project", removed)
      await create("enclosing-project", base)

      const del = async (path: string): Promise<number> =>
        (await jsonRequest(server, path, { method: "DELETE" })).status
      expect(await del("/v1/projects/kept-project")).toBe(204)
      expect(await del("/v1/projects/removed-project?deleteFiles=true")).toBe(204)
      expect(await del("/v1/projects/enclosing-project?deleteFiles=true")).toBe(204)

      expect(existsSync(join(kept, "src", "index.ts"))).toBe(true)
      expect(existsSync(removed)).toBe(false)
      expect(existsSync(join(base, "kept"))).toBe(true)
      expect(itemsOf((await jsonRequest(server, "/v1/projects")).body).length).toBe(0)
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })

  it("refuses to delete the root, the home folder, or relative paths", () => {
    expect(isDeletableProjectFolder("/")).toBe(false)
    expect(isDeletableProjectFolder(homedir())).toBe(false)
    expect(isDeletableProjectFolder(`${homedir()}/`)).toBe(false)
    expect(isDeletableProjectFolder("projects/app")).toBe(false)
    expect(isDeletableProjectFolder(join(homedir(), "src", "app"))).toBe(true)
  })

  it("creates scratch workspace projects and re-homes their sessions before the agent starts", async () => {
    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-scratch-root-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { server } = await start()

      const created = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({ id: "scratch-project" }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      const scratch = decodeProject(created.body)
      expect(scratch.id).toBe("scratch-project")
      expect(scratch.isScratch).toBe(true)
      const scratchFolder = scratch.locations[0]?.folderPath
      if (scratchFolder === undefined) throw new Error("missing scratch folder")
      expect(scratchFolder).toBe(join(worktreesRoot, "workspaces.noindex", scratch.name))
      expect(existsSync(scratchFolder)).toBe(true)

      const olderFolder = join(worktreesRoot, "workspaces", "older-scratch")
      mkdirSync(olderFolder, { recursive: true })
      const older = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: olderFolder }),
        method: "POST"
      })
      expect(decodeProject(older.body)).toMatchObject({
        isScratch: true,
        locations: [{ folderPath: olderFolder }]
      })

      const replay = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({ id: "scratch-project" }),
        method: "POST"
      })
      expect(replay.status).toBe(200)
      expect(idOf(replay.body)).toBe("scratch-project")
      expect(readdirSync(join(worktreesRoot, "workspaces.noindex"))).toHaveLength(1)

      const anonymous = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(anonymous.status).toBe(201)
      expect(decodeProject(anonymous.body).isScratch).toBe(true)
      expect(readdirSync(join(worktreesRoot, "workspaces.noindex"))).toHaveLength(2)

      resetRepoUrlDiscoveryCache()
      const listed = await jsonRequest(server, "/v1/projects", { method: "GET" })
      expect(listed.status).toBe(200)
      const listedScratch = decode(Schema.Array(Project))(listed.body).find(
        (project) => project.id === "scratch-project"
      )
      expect(listedScratch).toMatchObject({ isScratch: true })
      expect(listedScratch?.repoKey).toBeUndefined()

      const plainFolder = mkdtempSync(join(tmpdir(), "codevisor-plain-"))
      tempDirs.push(plainFolder)
      const plain = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
        method: "POST"
      })
      expect(plain.status).toBe(201)
      expect(decodeProject(plain.body).isScratch).toBeUndefined()

      const sessionResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "scratch-session",
          projectId: "scratch-project",
          harnessId: "codex",
          deferAgentSession: true
        }),
        method: "POST"
      })
      expect(sessionResponse.status).toBe(201)
      expect(field(sessionResponse.body, "cwd")).toBe(scratchFolder)

      const moved = await jsonRequest(server, "/v1/sessions/scratch-session", {
        body: JSON.stringify({ projectId: "plain-project" }),
        method: "PATCH"
      })
      expect(moved.status).toBe(200)
      expect(moved.body).toMatchObject({ projectId: "plain-project", cwd: plainFolder })

      expect(
        (
          await jsonRequest(server, "/v1/sessions/scratch-session", {
            body: JSON.stringify({ projectId: "missing-project" }),
            method: "PATCH"
          })
        ).status
      ).toBe(404)

      const startedResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "plain-project", harnessId: "codex" }),
        method: "POST"
      })
      expect(startedResponse.status).toBe(201)
      const startedId = idOf(startedResponse.body)
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${startedId}`, {
            body: JSON.stringify({ projectId: "scratch-project" }),
            method: "PATCH"
          })
        ).status
      ).toBe(409)

      expect(
        (await jsonRequest(server, "/v1/projects/scratch-project", { method: "DELETE" })).status
      ).toBe(204)
      expect(existsSync(scratchFolder)).toBe(false)
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })
})
