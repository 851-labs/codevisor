import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { foodWorktreeNames } from "@codevisor/worktrees"
import { jsonRequest, makeServices, run, runningServers, start, tempDirs } from "../test-support.js"

describe("project lifecycle routes", () => {
  it("cascades archive across projects, workspaces, and chats with provenance", async () => {
    const { server } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-cascade-"))
    tempDirs.push(folder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "cascade-project" }),
      method: "POST"
    })
    // A workspace in an unrelated project, present for every cascade below: it
    // must never be republished, or clients would move rows that never changed.
    const otherFolder = mkdtempSync(join(tmpdir(), "codevisor-cascade-other-"))
    tempDirs.push(otherFolder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: otherFolder, id: "bystander-project" }),
      method: "POST"
    })
    await jsonRequest(server, "/v1/workspaces/bystander-workspace", {
      body: JSON.stringify({
        projectId: "bystander-project",
        name: "bystander",
        hasCustomName: false
      }),
      method: "PUT"
    })
    const workspace = (
      await jsonRequest(server, "/v1/workspaces/cascade-workspace", {
        body: JSON.stringify({
          projectId: "cascade-project",
          name: "main",
          hasCustomName: false
        }),
        method: "PUT"
      })
    ).body as { readonly id: string }

    const makeSession = async (id: string) =>
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ id, projectId: "cascade-project", harnessId: "codex" }),
          method: "POST"
        })
      ).body as { readonly id: string }
    const cascaded = await makeSession("cascade-chat")
    const handArchived = await makeSession("hand-archived-chat")

    // The user archives one chat themselves, before any cascade runs.
    await jsonRequest(server, `/v1/sessions/${handArchived.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })

    const archivedStateOf = async (id: string) =>
      (
        (await jsonRequest(server, "/v1/sessions")).body as ReadonlyArray<{
          readonly id: string
          readonly isArchived: boolean
        }>
      ).find((session) => session.id === id)?.isArchived
    const workspaceArchived = async () =>
      (
        (await jsonRequest(server, "/v1/workspaces")).body as ReadonlyArray<{
          readonly id: string
          readonly isArchived: boolean
        }>
      ).find((candidate) => candidate.id === workspace.id)?.isArchived

    await jsonRequest(server, "/v1/projects/cascade-project", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(await archivedStateOf(cascaded.id)).toBe(true)
    expect(await workspaceArchived()).toBe(true)

    await jsonRequest(server, "/v1/projects/cascade-project", {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(await archivedStateOf(cascaded.id)).toBe(false)
    expect(await workspaceArchived()).toBe(false)
    // Provenance: the chat the user archived by hand is NOT resurrected by
    // unarchiving the project around it.
    expect(await archivedStateOf(handArchived.id)).toBe(true)

    // A workspace PATCH cascades one level down, to its own chats only.
    const inWorkspace = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          id: "workspace-chat",
          projectId: "cascade-project",
          harnessId: "codex",
          workspaceId: workspace.id
        }),
        method: "POST"
      })
    ).body as { readonly id: string }

    await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(await archivedStateOf(inWorkspace.id)).toBe(true)
    // A sibling chat outside the workspace is untouched.
    expect(await archivedStateOf(cascaded.id)).toBe(false)

    await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(await archivedStateOf(inWorkspace.id)).toBe(false)

    const bystander = (
      (await jsonRequest(server, "/v1/workspaces")).body as ReadonlyArray<{
        readonly id: string
        readonly isArchived: boolean
      }>
    ).find((candidate) => candidate.id === "bystander-workspace")
    expect(bystander?.isArchived).toBe(false)

    // A PATCH that says nothing about archiving skips the cascade entirely
    // rather than republishing every session as unchanged.
    const renamed = await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ name: "renamed" }),
      method: "PATCH"
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body).toMatchObject({ name: "renamed", isArchived: false })
    expect(await archivedStateOf(inWorkspace.id)).toBe(false)
  })

  it("archives a chat with no worktree without touching the filesystem", async () => {
    // Non-git projects never get a worktree, so archiving is a pure flag flip
    // — the snapshot machinery must not engage at all.
    const { server } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-plain-archive-"))
    tempDirs.push(folder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "plain-archive-project" }),
      method: "POST"
    })
    const session = (
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "plain-archive-project",
          harnessId: "test",
          deferAgentSession: true
        }),
        method: "POST"
      })
    ).body as { readonly id: string }

    const archived = await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(archived.body).toMatchObject({ isArchived: true })

    // Restoring finds no snapshot record and still succeeds.
    const restored = await jsonRequest(server, `/v1/sessions/${session.id}`, {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(restored.body).toMatchObject({ isArchived: false })
    expect(existsSync(folder)).toBe(true)
  })

  it("lists and applies a project's configured worktree base branch", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })
    const root = mkdtempSync(join(tmpdir(), "codevisor-project-base-"))
    const worktreesRoot = join(root, "worktrees")
    const origin = join(root, "origin")
    const repo = join(root, "repo")
    const nonGitRepo = join(root, "non-git")
    mkdirSync(origin)
    mkdirSync(nonGitRepo)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    tempDirs.push(root)

    try {
      await git(["init", "-b", "main"], origin)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "main"],
        origin
      )
      await git(["checkout", "-b", "release/next"], origin)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "release"],
        origin
      )
      const releaseSha = (await git(["rev-parse", "HEAD"], origin)).stdout.trim()
      await git(["checkout", "main"], origin)
      await git(["clone", origin, repo], root)

      const { server } = await start()
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: nonGitRepo, id: "non-git-project" }),
        method: "POST"
      })
      const nonGitBranches = await jsonRequest(server, "/v1/projects/non-git-project/git/branches")
      expect(nonGitBranches.status).toBe(422)

      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: repo, id: "configured-base-project" }),
        method: "POST"
      })

      const branches = await jsonRequest(
        server,
        "/v1/projects/configured-base-project/git/branches"
      )
      expect(branches.status).toBe(200)
      expect(branches.body).toEqual(
        expect.arrayContaining([
          { remote: "origin", branch: "main", isDefault: true },
          { remote: "origin", branch: "release/next", isDefault: false }
        ])
      )

      const configured = await jsonRequest(server, "/v1/projects/configured-base-project", {
        body: JSON.stringify({
          worktreeBase: { remote: "origin", branch: "release/next" }
        }),
        method: "PATCH"
      })
      expect(configured.body).toMatchObject({
        worktreeBase: { remote: "origin", branch: "release/next" }
      })

      const created = await jsonRequest(server, "/v1/projects/configured-base-project/worktrees", {
        body: JSON.stringify({ name: "from-release" }),
        method: "POST"
      })
      expect(created.status).toBe(201)
      const worktreePath = (created.body as { readonly path: string }).path
      expect((await git(["rev-parse", "HEAD"], worktreePath)).stdout.trim()).toBe(releaseSha)

      await jsonRequest(server, "/v1/projects/configured-base-project", {
        body: JSON.stringify({ worktreeBase: { remote: "origin", branch: "missing" } }),
        method: "PATCH"
      })
      const missing = await jsonRequest(server, "/v1/projects/configured-base-project/worktrees", {
        body: JSON.stringify({ name: "missing-base" }),
        method: "POST"
      })
      expect(missing.status).toBe(422)
      expect((missing.body as { readonly error: string }).error).toContain("Manage Project")
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })

  it("uses food names with four-digit suffixes for development worktrees", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })
    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-development-worktrees-"))
    tempDirs.push(worktreesRoot)
    process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
    try {
      const { services } = await makeServices("server-dev")
      const server = await run(
        startCodevisorServer(
          services,
          defaultServerConfig({
            id: "server-dev",
            port: 0,
            worktreeNameStyle: "development"
          })
        )
      )
      runningServers.push(server)
      const repoFolder = mkdtempSync(join(tmpdir(), "codevisor-development-repo-"))
      tempDirs.push(repoFolder)
      await git(["init"], repoFolder)
      await git(
        ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
        repoFolder
      )
      expect(
        (
          await jsonRequest(server, "/v1/projects", {
            body: JSON.stringify({ folderPath: repoFolder, id: "food-project" }),
            method: "POST"
          })
        ).status
      ).toBe(201)

      const response = await jsonRequest(server, "/v1/projects/food-project/worktrees", {
        method: "POST"
      })
      expect(response.status).toBe(201)
      const name = (response.body as { readonly name: string }).name
      const match = /^(.*)-(\d{4})$/.exec(name)
      expect(match).not.toBeNull()
      expect(foodWorktreeNames).toContain(match?.[1])

      // Scratch workspace folders draw from the same development pool.
      const scratch = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(scratch.status).toBe(201)
      const scratchName = (scratch.body as { readonly name: string }).name
      const scratchMatch = /^(.*)-(\d{4})$/.exec(scratchName)
      expect(scratchMatch).not.toBeNull()
      expect(foodWorktreeNames).toContain(scratchMatch?.[1])
    } finally {
      delete process.env["CODEVISOR_WORKTREES_ROOT"]
    }
  })
})
