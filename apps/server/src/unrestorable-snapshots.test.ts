import { execFile } from "node:child_process"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { Worktree } from "@codevisor/api"
import { listSnapshotRefWorktreeIds } from "@codevisor/worktrees"
import { Schema } from "effect"
import { describe, expect, it, vi } from "vitest"

import { archiveJobs } from "./archive-jobs.js"
import { jsonRequest, run, start, tempDirs } from "./test-support.js"
import { forgetUnrestorableSnapshots } from "./unrestorable-snapshots.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })

const setUp = async () => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-snapshots-"))
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
  const worktree = Schema.decodeUnknownSync(Worktree)(
    (
      await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ name: "sushi" }),
        method: "POST"
      })
    ).body
  )
  await jsonRequest(server, "/v1/workspaces/work", {
    body: JSON.stringify({
      projectId: "git-project",
      name: "Work",
      hasCustomName: false,
      rootDirectory: worktree.path
    }),
    method: "PUT"
  })
  return { server, services, repoFolder }
}

type Setup = Awaited<ReturnType<typeof setUp>>

const snapshotsLeft = async ({ services, repoFolder }: Setup) => ({
  archived: (await run(services.db.listArchivedWorktrees("git-project"))).length,
  refs: (await listSnapshotRefWorktreeIds(repoFolder)).length
})

describe("unrestorable snapshots", () => {
  it("forgets the snapshot of a workspace that was deleted", async () => {
    const setup = await setUp()
    await jsonRequest(setup.server, "/v1/workspaces/work", { method: "DELETE" })
    await archiveJobs(setup.services).idle()
    expect(await snapshotsLeft(setup)).toEqual({ archived: 1, refs: 1 })

    await forgetUnrestorableSnapshots(setup.services, "server-a")

    expect(await snapshotsLeft(setup)).toEqual({ archived: 0, refs: 0 })
  })

  it("keeps the snapshot an archived workspace can still restore", async () => {
    const setup = await setUp()
    await jsonRequest(setup.server, "/v1/workspaces/work", {
      body: JSON.stringify({ isArchived: true }),
      method: "PATCH"
    })
    await archiveJobs(setup.services).idle()

    await forgetUnrestorableSnapshots(setup.services, "server-a")

    expect(await snapshotsLeft(setup)).toEqual({ archived: 1, refs: 1 })
  })
})
