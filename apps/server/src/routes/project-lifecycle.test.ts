import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { foodWorktreeNames } from "@codevisor/worktrees"
import { describe, expect, it } from "vitest"

import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, makeServices, run, runningServers, start, tempDirs } from "../test-support.js"

describe("project lifecycle routes", () => {
  it("archives workspaces independently, leaving chats and bystanders alone", async () => {
    // The workspace is the only thing that carries archive state, so there is
    // no cascade to get wrong: archiving one workspace must not touch another,
    // and a chat has no archive flag of its own to fall out of step with.
    const { server } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-archive-"))
    tempDirs.push(folder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "archive-project" }),
      method: "POST"
    })
    const otherFolder = mkdtempSync(join(tmpdir(), "codevisor-archive-other-"))
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
      await jsonRequest(server, "/v1/workspaces/archive-workspace", {
        body: JSON.stringify({
          projectId: "archive-project",
          name: "main",
          hasCustomName: false
        }),
        method: "PUT"
      })
    ).body as { readonly id: string }
    await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        id: "workspace-chat",
        projectId: "archive-project",
        harnessId: "codex",
        workspaceId: workspace.id
      }),
      method: "POST"
    })

    const archivedStateOf = async (id: string) =>
      (
        (await jsonRequest(server, "/v1/workspaces")).body as ReadonlyArray<{
          readonly id: string
          readonly isArchived: boolean
        }>
      ).find((candidate) => candidate.id === id)?.isArchived
    const paneCount = async (id: string) =>
      (
        (await jsonRequest(server, "/v1/workspace-snapshot")).body as {
          readonly panes: ReadonlyArray<{ readonly workspaceId: string }>
        }
      ).panes.filter((pane) => pane.workspaceId === id).length

    expect(await paneCount(workspace.id)).toBe(1)

    await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(await archivedStateOf(workspace.id)).toBe(true)
    // The tab survives the archive so restoring reopens exactly what was open.
    expect(await paneCount(workspace.id)).toBe(1)
    expect(await archivedStateOf("bystander-workspace")).toBe(false)

    await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(await archivedStateOf(workspace.id)).toBe(false)
    expect(await paneCount(workspace.id)).toBe(1)

    // A PATCH that says nothing about archiving leaves the bit alone.
    const renamed = await jsonRequest(server, `/v1/workspaces/${workspace.id}`, {
      body: JSON.stringify({ name: "renamed" }),
      method: "PATCH"
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body).toMatchObject({ name: "renamed", isArchived: false })
  })

  it("archives a workspace with no worktree without touching the filesystem", async () => {
    // Non-git projects never get a worktree, so archiving is a pure flag flip
    // — the snapshot machinery must not engage at all.
    const { server } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-plain-archive-"))
    tempDirs.push(folder)
    await jsonRequest(server, "/v1/projects", {
      body: JSON.stringify({ folderPath: folder, id: "plain-archive-project" }),
      method: "POST"
    })
    await jsonRequest(server, "/v1/workspaces/plain-workspace", {
      body: JSON.stringify({
        projectId: "plain-archive-project",
        name: "plain",
        hasCustomName: false
      }),
      method: "PUT"
    })
    await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        projectId: "plain-archive-project",
        workspaceId: "plain-workspace",
        harnessId: "test",
        deferAgentSession: true
      }),
      method: "POST"
    })

    const archived = await jsonRequest(server, "/v1/workspaces/plain-workspace", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(archived.body).toMatchObject({ isArchived: true })

    // Restoring finds no snapshot record and still succeeds.
    const restored = await jsonRequest(server, "/v1/workspaces/plain-workspace", {
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
