import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, Project, Workspace, WorkspaceSnapshot, Worktree } from "@codevisor/api"
import { foodWorktreeNames } from "@codevisor/worktrees"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { defaultServerConfig, startCodevisorServer } from "../server.js"
import { jsonRequest, makeServices, run, runningServers, start, tempDirs } from "../test-support.js"
import { field, idOf } from "./response-test-support.js"

describe("project lifecycle routes", () => {
  it("archives workspaces independently, leaving chats and bystanders alone", async () => {
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
    const workspaceId = idOf(
      (
        await jsonRequest(server, "/v1/workspaces/archive-workspace", {
          body: JSON.stringify({
            projectId: "archive-project",
            name: "main",
            hasCustomName: false
          }),
          method: "PUT"
        })
      ).body
    )
    await jsonRequest(server, "/v1/sessions", {
      body: JSON.stringify({
        id: "workspace-chat",
        projectId: "archive-project",
        harnessId: "codex",
        workspaceId
      }),
      method: "POST"
    })

    const archivedStateOf = async (id: string) =>
      decode(Schema.Array(Workspace))((await jsonRequest(server, "/v1/workspaces")).body).find(
        (candidate) => candidate.id === id
      )?.isArchived
    const paneCount = async (id: string) =>
      decode(WorkspaceSnapshot)(
        (await jsonRequest(server, "/v1/workspace-snapshot")).body
      ).panes.filter((pane) => pane.workspaceId === id).length

    expect(await paneCount(workspaceId)).toBe(1)

    await jsonRequest(server, `/v1/workspaces/${workspaceId}`, {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    expect(await archivedStateOf(workspaceId)).toBe(true)
    expect(await paneCount(workspaceId)).toBe(1)
    expect(await archivedStateOf("bystander-workspace")).toBe(false)

    await jsonRequest(server, `/v1/workspaces/${workspaceId}`, {
      body: JSON.stringify({ isArchived: false }),
      method: "PATCH"
    })
    expect(await archivedStateOf(workspaceId)).toBe(false)
    expect(await paneCount(workspaceId)).toBe(1)

    const renamed = await jsonRequest(server, `/v1/workspaces/${workspaceId}`, {
      body: JSON.stringify({ name: "renamed" }),
      method: "PATCH"
    })
    expect(renamed.status).toBe(200)
    expect(renamed.body).toMatchObject({ name: "renamed", isArchived: false })
  })

  it("archives a workspace with no worktree without touching the filesystem", async () => {
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
    vi.stubEnv("CODEVISOR_WORKTREES_ROOT", worktreesRoot)
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
      const worktreePath = decode(Worktree)(created.body).path
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
      expect(field(missing.body, "error")).toContain("Manage Project")
    } finally {
      vi.unstubAllEnvs()
    }
  })

  it("uses food names with four-digit suffixes for development worktrees", async () => {
    const execFileAsync = promisify(execFile)
    const git = (args: ReadonlyArray<string>, cwd: string) =>
      execFileAsync("git", [...args], { cwd })
    const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-development-worktrees-"))
    tempDirs.push(worktreesRoot)
    vi.stubEnv("CODEVISOR_WORKTREES_ROOT", worktreesRoot)
    try {
      const { services } = await makeServices("server-dev")
      const server = await run(
        startCodevisorServer(
          services,
          defaultServerConfig({
            bootId: "test-boot",
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
      const name = decode(Worktree)(response.body).name
      const match = /^(.*)-(\d{4})$/.exec(name)
      expect(match).not.toBeNull()
      expect(foodWorktreeNames).toContain(match?.[1])

      const scratch = await jsonRequest(server, "/v1/projects/scratch", {
        body: JSON.stringify({}),
        method: "POST"
      })
      expect(scratch.status).toBe(201)
      const scratchName = decode(Project)(scratch.body).name
      const scratchMatch = /^(.*)-(\d{4})$/.exec(scratchName)
      expect(scratchMatch).not.toBeNull()
      expect(foodWorktreeNames).toContain(scratchMatch?.[1])
    } finally {
      vi.unstubAllEnvs()
    }
  })
})
