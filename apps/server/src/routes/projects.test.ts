import { Effect } from "effect"
import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from "node:fs"
import { homedir, tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import {
  jsonRequest,
  makeServices,
  run,
  runningServers,
  start,
  startWithApp,
  tempDirs
} from "../test-support.js"
import { resetRepoUrlDiscoveryCache } from "./project-repo-identity.js"

const execFileAsync = promisify(execFile)

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
    runningServers.push(server)

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

  it("keeps unavailable harness stores from breaking project recommendations", async () => {
    const { agents, services } = await makeServices("server-a")
    const server = await startWithApp({
      ...services,
      agents: {
        ...agents,
        listAgentSessions: () => Effect.die(new Error("native store unavailable"))
      }
    })
    runningServers.push(server)

    const response = await jsonRequest(server, "/v1/projects/recommendations")

    expect(response.status).toBe(200)
    expect(response.body).toEqual([])
  })

  it("clones a git remote into the managed repos dir as a project", async () => {
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })

    const reposRoot = mkdtempSync(join(tmpdir(), "codevisor-repos-"))
    tempDirs.push(reposRoot)
    process.env["CODEVISOR_REPOS_ROOT"] = reposRoot
    try {
      const { server, services } = await start()
      const origin = mkdtempSync(join(tmpdir(), "codevisor-origin-"))
      tempDirs.push(origin)
      const originRepo = join(origin, "widget.git")
      mkdirSync(originRepo)
      await git(["init"], originRepo)
      writeFileSync(join(originRepo, "README.md"), "hello")
      await git(["add", "."], originRepo)
      await git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "init"], originRepo)

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

      // Clone progress reached the event log under the client-supplied id.
      const events = await run(services.db.listSubjectEvents("cloned-project"))
      const states = events
        .filter((event) => event.kind === "project.setup")
        .map((event) => (event.payload as { state: string }).state)
      expect(states[0]).toBe("started")
      expect(states.at(-1)).toBe("completed")

      // A second clone of the same remote under an explicit name gets its
      // own directory and a server-generated project id.
      const renamed = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url, name: "widget-two" }),
        method: "POST"
      })
      expect(renamed.status).toBe(201)
      expect(renamed.body).toMatchObject({
        name: "widget-two",
        locations: [{ folderPath: join(reposRoot, "widget-two") }]
      })

      // Same destination again: conflict, with an actionable code.
      const duplicate = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url }),
        method: "POST"
      })
      expect(duplicate.status).toBe(409)
      expect(duplicate.body).toMatchObject({ code: "already_exists" })

      // Not a git URL at all.
      const invalid = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "not a url" }),
        method: "POST"
      })
      expect(invalid.status).toBe(400)
      expect(invalid.body).toMatchObject({ code: "invalid_url" })

      // A URL no project name can be derived from (scp-style syntax).
      const unnameable = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ url: "git@example.com:acme/--.git" }),
        method: "POST"
      })
      expect(unnameable.status).toBe(400)
      expect((unnameable.body as { error: string }).error).toContain("name")

      // A well-formed URL to a repo that does not exist: the clone fails with
      // a classified error, publishes `failed`, and leaves no partial dir.
      const missing = await jsonRequest(server, "/v1/projects/from-git", {
        body: JSON.stringify({ id: "missing-project", url: `file://${origin}/gone.git` }),
        method: "POST"
      })
      expect(missing.status).toBe(422)
      expect((missing.body as { code?: string }).code).toBeDefined()
      expect(existsSync(join(reposRoot, "gone"))).toBe(false)
      const failedEvents = await run(services.db.listSubjectEvents("missing-project"))
      expect(
        failedEvents.some(
          (event) =>
            event.kind === "project.setup" &&
            (event.payload as { state: string }).state === "failed"
        )
      ).toBe(true)
    } finally {
      delete process.env["CODEVISOR_REPOS_ROOT"]
    }
  })

  it("addresses projects by id case-insensitively", async () => {
    const { server } = await start()
    const lowerId = "0d604f39-364b-4a17-8fd8-21bddd8c1399"
    const upperId = lowerId.toUpperCase()

    // A client that sends an uppercase UUID (Swift) has it canonicalized to
    // lowercase, so ids stay consistent across clients.
    const created = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect(created.status).toBe(201)
    expect((created.body as { id: string }).id).toBe(lowerId)

    // Re-syncing the same project (uppercase again) is idempotent — no
    // duplicate row, no merge into a differently-cased id.
    const resync = await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: "/tmp/case-project", id: upperId }),
      method: "POST"
    })
    expect((resync.body as { id: string }).id).toBe(lowerId)
    expect(((await jsonRequest(server, "/v1/projects")).body as Array<unknown>).length).toBe(1)

    // A client that stores the id uppercase (Swift's UUID) resolves the
    // lowercase-stored project instead of hitting a spurious "Project not
    // found". (A later 4xx for harness/account reasons is unrelated.)
    const session = await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({ projectId: upperId, harnessId: "codex" }),
      method: "POST"
    })
    expect(session.status).not.toBe(404)
    expect(JSON.stringify(session.body)).not.toContain("Project not found")

    // The worktree route resolves the project by the uppercase URL id too.
    const worktree = await jsonRequest(server, `/v1/projects/${upperId}/worktrees`, {
      body: JSON.stringify({ name: "feature" }),
      method: "POST"
    })
    expect(worktree.status).not.toBe(404)
    expect(JSON.stringify(worktree.body)).not.toContain("Project not found")
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
      const scratch = created.body as {
        readonly id: string
        readonly name: string
        readonly isScratch?: boolean
        readonly locations: ReadonlyArray<{ readonly folderPath: string }>
      }
      expect(scratch.id).toBe("scratch-project")
      expect(scratch.isScratch).toBe(true)
      const scratchFolder = scratch.locations[0]?.folderPath as string
      expect(scratchFolder).toBe(join(worktreesRoot, "workspaces", scratch.name))
      expect(existsSync(scratchFolder)).toBe(true)

      // Idempotent per client-supplied id: replaying returns the existing
      // project instead of allocating a second folder.
      const replay = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({ id: "scratch-project" }),
        method: "POST"
      })
      expect(replay.status).toBe(200)
      expect((replay.body as { readonly id: string }).id).toBe("scratch-project")
      expect(readdirSync(join(worktreesRoot, "workspaces"))).toHaveLength(1)

      // Without a client id the server mints one — and a fresh folder.
      const anonymous = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(anonymous.status).toBe(201)
      expect((anonymous.body as { readonly isScratch?: boolean }).isScratch).toBe(true)
      expect(readdirSync(join(worktreesRoot, "workspaces"))).toHaveLength(2)

      // Listing never probes a scratch folder for a remote: it is not a
      // repository, and the row stays unlinked.
      resetRepoUrlDiscoveryCache()
      const listed = await jsonRequest(server, "/v1/projects", { method: "GET" })
      expect(listed.status).toBe(200)
      const listedScratch = (
        listed.body as ReadonlyArray<{
          readonly id: string
          readonly repoKey?: string
          readonly isScratch?: boolean
        }>
      ).find((project) => project.id === "scratch-project")
      expect(listedScratch).toMatchObject({ isScratch: true })
      expect(listedScratch?.repoKey).toBeUndefined()

      // An ordinary project is not flagged as scratch.
      const plainFolder = mkdtempSync(join(tmpdir(), "codevisor-plain-"))
      tempDirs.push(plainFolder)
      const plain = await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
        method: "POST"
      })
      expect(plain.status).toBe(201)
      expect((plain.body as { readonly isScratch?: boolean }).isScratch).toBeUndefined()

      // A deferred session starts life in the scratch folder…
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
      expect((sessionResponse.body as { readonly cwd?: string }).cwd).toBe(scratchFolder)

      // …and can be re-homed to a real project while the agent hasn't started.
      const moved = await jsonRequest(server, "/v1/sessions/scratch-session", {
        body: JSON.stringify({ projectId: "plain-project" }),
        method: "PATCH"
      })
      expect(moved.status).toBe(200)
      expect(moved.body).toMatchObject({ projectId: "plain-project", cwd: plainFolder })

      // Moving to a project with no folder on this machine is refused up front.
      expect(
        (
          await jsonRequest(server, "/v1/sessions/scratch-session", {
            body: JSON.stringify({ projectId: "missing-project" }),
            method: "PATCH"
          })
        ).status
      ).toBe(404)

      // Once an agent session exists the move is refused.
      const startedResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "plain-project", harnessId: "codex" }),
        method: "POST"
      })
      expect(startedResponse.status).toBe(201)
      const startedId = (startedResponse.body as { readonly id: string }).id
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${startedId}`, {
            body: JSON.stringify({ projectId: "scratch-project" }),
            method: "PATCH"
          })
        ).status
      ).toBe(409)

      // Deleting the scratch project retires its (still empty) folder.
      expect(
        (await jsonRequest(server, "/v1/projects/scratch-project", { method: "DELETE" })).status
      ).toBe(204)
      expect(existsSync(scratchFolder)).toBe(false)
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })
})
