import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { listSnapshotRefWorktreeIds } from "@codevisor/worktrees"
import { describe, expect, it, vi } from "vitest"

import { archiveJobs } from "./archive-jobs.js"
import { jsonRequest, run, start, tempDirs } from "./test-support.js"
import { withWorktreeLifecycle } from "./worktree-lifecycle.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })

/// A started server with a git project and one workspace on its own worktree.
const setUp = async () => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-archive-jobs-"))
  tempDirs.push(worktreesRoot)
  vi.stubEnv("CODEVISOR_WORKTREES_ROOT", worktreesRoot)
  const { server, services } = await start()
  const repoFolder = join(worktreesRoot, "repo")
  mkdirSync(repoFolder)
  await git(["init"], repoFolder)
  await git(
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
    repoFolder
  )
  await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repoFolder, id: "git-project" }),
    method: "POST"
  })
  const worktree = (
    await jsonRequest(server, "/v1/projects/git-project/worktrees", {
      body: JSON.stringify({ name: "sushi" }),
      method: "POST"
    })
  ).body as { readonly id: string; readonly path: string }
  await jsonRequest(server, "/v1/workspaces/work", {
    body: JSON.stringify({
      projectId: "git-project",
      name: "Work",
      hasCustomName: false,
      rootDirectory: worktree.path
    }),
    method: "PUT"
  })
  return { server, services, repoFolder, worktree }
}

describe("archive jobs", () => {
  it("does nothing when the workspace is unarchived before its job runs", async () => {
    const { server, services, repoFolder, worktree } = await setUp()
    // Holding the worktree's lifecycle lock keeps the job from starting.
    const gate = Promise.withResolvers<void>()
    const held = withWorktreeLifecycle(services, worktree.path, () => gate.promise)
    expect(
      (
        await jsonRequest(server, "/v1/workspaces/work", {
          body: JSON.stringify({ isArchived: true }),
          method: "PATCH"
        })
      ).status
    ).toBe(200)
    await run(services.db.updateWorkspace("work", { isArchived: false }))
    gate.resolve()
    await held
    await archiveJobs(services).idle()

    expect(existsSync(worktree.path)).toBe(true)
    expect(await listSnapshotRefWorktreeIds(repoFolder)).toEqual([])
    expect(await run(services.db.listArchivedWorktrees("git-project"))).toEqual([])
  })

  it("still reclaims a deleted workspace's worktree without resurrecting it", async () => {
    const { server, services, worktree } = await setUp()
    // An ignored file makes the archive want to report what it dropped.
    writeFileSync(join(worktree.path, ".gitignore"), ".env\n")
    writeFileSync(join(worktree.path, ".env"), "SECRET=1\n")
    expect((await jsonRequest(server, "/v1/workspaces/work", { method: "DELETE" })).status).toBe(
      204
    )
    await archiveJobs(services).idle()

    expect(existsSync(worktree.path)).toBe(false)
    expect(
      (await run(services.db.listArchivedWorktrees("git-project"))).map(
        (archived) => archived.state
      )
    ).toEqual(["complete"])
    // Clients already dropped the workspace; an update after the delete would
    // bring it back.
    const kinds = (await run(services.db.listSubjectEvents("work"))).map((event) => event.kind)
    expect(kinds.at(-1)).toBe("workspace.deleted")
  })

  it("keeps the files when a process cannot be stopped, and keeps serving later jobs", async () => {
    const { server, services, worktree } = await setUp()
    await jsonRequest(server, "/v1/workspaces/work/panes/term", {
      method: "PUT",
      body: JSON.stringify({
        providerId: "codevisor",
        paneType: "terminal",
        resourceKind: "terminal",
        resourceId: "stubborn",
        title: "Terminal"
      })
    })
    services.terminal.registerExternalTerminal(
      { sessionId: "stubborn" },
      {
        stop: async () => {
          throw new Error("refused to stop")
        },
        kill: vi.fn(),
        write: vi.fn(),
        resize: vi.fn()
      }
    )
    const archive = (isArchived: boolean) =>
      jsonRequest(server, "/v1/workspaces/work", {
        body: JSON.stringify({ isArchived }),
        method: "PATCH"
      })
    expect((await archive(true)).status).toBe(200)
    await archiveJobs(services).idle()
    expect(existsSync(worktree.path)).toBe(true)

    // The failed job must not wedge the queue for the next archive.
    await archive(false)
    await run(services.db.deleteWorkspacePane("work", "term"))
    expect((await archive(true)).status).toBe(200)
    await archiveJobs(services).idle()
    expect(existsSync(worktree.path)).toBe(false)
  })
})
