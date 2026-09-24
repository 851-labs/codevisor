import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { listSnapshotRefWorktreeIds, snapshotRefFor } from "@codevisor/worktrees"
import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { defaultServerConfig } from "./server-config.js"
import { jsonRequest, run, start, tempDirs } from "./test-support.js"
import { discardProjectWorktrees, reconcileWorktreeArchives } from "./worktree-reconcile.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })

const withWorktreesRoot = async <A>(body: () => Promise<A>): Promise<A> => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-reconcile-"))
  tempDirs.push(worktreesRoot)
  process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
  try {
    return await body()
  } finally {
    delete process.env["CODEVISOR_WORKTREES_ROOT"]
  }
}

/// A started server owning one git-backed project, plus a helper that creates
/// worktrees through the real route so their rows, branches and directories all
/// exist exactly as production would leave them.
const setUpProject = async () => {
  const { server, services } = await start()
  // makeServices' temp dir (the newest entry) holds the server database.
  const serverDatabasePath = join(tempDirs[tempDirs.length - 1] as string, "codevisor.sqlite")
  const repoRoot = mkdtempSync(join(tmpdir(), "codevisor-reconcile-repo-"))
  tempDirs.push(repoRoot)
  const repoFolder = join(repoRoot, "repo")
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
  const makeWorktree = async (name: string) =>
    (
      await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ name }),
        method: "POST"
      })
    ).body as { readonly id: string; readonly name: string; readonly path: string }
  const config = defaultServerConfig({ id: "server-a", port: 0 })
  return { server, services, repoFolder, makeWorktree, config, serverDatabasePath }
}

describe("worktree archive reconciliation", () => {
  it("finishes an interrupted archive and completes its record", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config } = await setUpProject()
      const worktree = await makeWorktree("sushi")

      // Exactly the state a crash between recording the archive and deleting
      // the files leaves: a durable snapshot, a `pending` row, and a worktree
      // still on disk with its row intact.
      await run(
        services.db.createArchivedWorktree({
          id: worktree.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: worktree.name,
          branch: `codevisor/${worktree.name}`,
          parentSha: (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim(),
          snapshotRef: snapshotRefFor(worktree.id),
          createdAt: new Date().toISOString(),
          state: "pending"
        })
      )
      expect(existsSync(worktree.path)).toBe(true)

      await reconcileWorktreeArchives(services, config)

      expect(existsSync(worktree.path)).toBe(false)
      expect(
        (await run(services.db.listArchivedWorktrees("git-project"))).find(
          (archived) => archived.id === worktree.id
        )?.state
      ).toBe("complete")
      // The name is back in the pool: the row that reserved it is gone.
      expect(await run(services.db.listWorktrees("git-project"))).toEqual([])
    })
  })

  it("drops worktree rows whose directory vanished", async () => {
    await withWorktreesRoot(async () => {
      const { services, makeWorktree, config } = await setUpProject()
      const worktree = await makeWorktree("ramen")
      rmSync(worktree.path, { recursive: true, force: true })

      await reconcileWorktreeArchives(services, config)

      // A stale row keeps its (finite) name reserved and makes restore claim
      // success for files that are not there.
      expect(await run(services.db.listWorktrees("git-project"))).toEqual([])
    })
  })

  it("prunes snapshot refs nothing can restore and keeps the ones that can", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config } = await setUpProject()
      const kept = await makeWorktree("tacos")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await git(["update-ref", snapshotRefFor(kept.id), parentSha], repoFolder)
      await run(
        services.db.createArchivedWorktree({
          id: kept.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: kept.name,
          branch: `codevisor/${kept.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(kept.id),
          createdAt: new Date().toISOString(),
          state: "complete"
        })
      )
      // An archive interrupted BEFORE its row was written leaves this: a ref
      // no row names, unreachable by restore and immune to `git gc`.
      await git(["update-ref", snapshotRefFor("orphan-worktree"), parentSha], repoFolder)

      await reconcileWorktreeArchives(services, config)

      expect([...(await listSnapshotRefWorktreeIds(repoFolder))]).toEqual([kept.id])
    })
  })

  it("skips archives owned by another server and projects it cannot resolve", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config } = await setUpProject()
      const worktree = await makeWorktree("curry")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await run(
        services.db.createArchivedWorktree({
          id: worktree.id,
          projectId: "git-project",
          serverId: "server-elsewhere",
          originalName: worktree.name,
          branch: `codevisor/${worktree.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(worktree.id),
          createdAt: new Date().toISOString(),
          state: "pending"
        })
      )

      await reconcileWorktreeArchives(services, config)

      // Another machine owns those files; this server must not touch them.
      expect(existsSync(worktree.path)).toBe(true)
      expect(
        (await run(services.db.listArchivedWorktrees("git-project"))).find(
          (archived) => archived.id === worktree.id
        )?.state
      ).toBe("pending")
    })
  })

  it("removes every worktree, branch and snapshot a deleted project owned", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config } = await setUpProject()
      const live = await makeWorktree("pasta")
      const archived = await makeWorktree("risotto")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await git(["update-ref", snapshotRefFor(archived.id), parentSha], repoFolder)
      await run(
        services.db.createArchivedWorktree({
          id: archived.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: archived.name,
          branch: `codevisor/${archived.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(archived.id),
          createdAt: new Date().toISOString(),
          state: "complete"
        })
      )
      const project = (await run(services.db.listProjects)).find(
        (candidate) => candidate.id === "git-project"
      )!

      await discardProjectWorktrees(services, config.id, project)

      // Deleting a project is permanent, so nothing it owned may survive:
      // row deletion cascades in SQLite, but none of this does.
      expect(existsSync(live.path)).toBe(false)
      expect(await listSnapshotRefWorktreeIds(repoFolder)).toEqual([])
      const branches = (
        await git(["for-each-ref", "--format=%(refname)", "refs/heads/"], repoFolder)
      ).stdout
      expect(branches).not.toContain("codevisor/pasta")
      expect(branches).not.toContain("codevisor/risotto")
    })
  })

  it("leaves a project whose folder this server cannot resolve alone", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config, serverDatabasePath } =
        await setUpProject()
      const worktree = await makeWorktree("gnocchi")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await git(["update-ref", snapshotRefFor("orphan-worktree"), parentSha], repoFolder)
      await run(
        services.db.createArchivedWorktree({
          id: worktree.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: worktree.name,
          branch: `codevisor/${worktree.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(worktree.id),
          createdAt: new Date().toISOString(),
          state: "pending"
        })
      )
      // The project's only checkout now belongs to another machine, so this
      // server has no folder to run git in and must skip the project entirely
      // rather than guess at a path.
      const sqlite = new Database(serverDatabasePath)
      sqlite.prepare("update project_locations set server_id = 'server-elsewhere'").run()
      sqlite.close()

      await reconcileWorktreeArchives(services, config)

      expect(existsSync(worktree.path)).toBe(true)
      // The orphan ref survives too: a repository this server cannot locate is
      // not one it may prune.
      expect(await listSnapshotRefWorktreeIds(repoFolder)).toEqual(["orphan-worktree"])
    })
  })

  it("completes a pending archive whose files and row are already gone", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config } = await setUpProject()
      const worktree = await makeWorktree("polenta")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await run(
        services.db.createArchivedWorktree({
          id: worktree.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: worktree.name,
          branch: `codevisor/${worktree.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(worktree.id),
          createdAt: new Date().toISOString(),
          state: "pending"
        })
      )
      // A crash AFTER the files went but before the row was promoted. There is
      // nothing left to delete, so the pass only has to finish the bookkeeping.
      rmSync(worktree.path, { recursive: true, force: true })
      await run(services.db.deleteWorktree(worktree.id))

      await reconcileWorktreeArchives(services, config)

      expect(
        (await run(services.db.listArchivedWorktrees("git-project"))).find(
          (archived) => archived.id === worktree.id
        )?.state
      ).toBe("complete")
    })
  })

  it("never touches rows another machine owns, and survives a stubborn worktree", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config, serverDatabasePath } =
        await setUpProject()
      const foreign = await makeWorktree("linguine")
      const stubborn = await makeWorktree("rigatoni")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await git(["update-ref", snapshotRefFor(foreign.id), parentSha], repoFolder)
      await run(
        services.db.createArchivedWorktree({
          id: foreign.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: foreign.name,
          branch: `codevisor/${foreign.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(foreign.id),
          createdAt: new Date().toISOString(),
          state: "complete"
        })
      )
      // Reassign both records to another machine, and delete the directory
      // under one of them. Server databases are single-owner, but a botched
      // identity adoption can leave foreign rows behind: they must be skipped,
      // not reclaimed, because their files belong to someone else.
      const sqlite = new Database(serverDatabasePath)
      sqlite
        .prepare("update worktrees set server_id = 'server-elsewhere' where id = ?")
        .run(foreign.id)
      sqlite
        .prepare("update archived_worktrees set server_id = 'server-elsewhere' where id = ?")
        .run(foreign.id)
      sqlite.close()
      rmSync(foreign.path, { recursive: true, force: true })

      await reconcileWorktreeArchives(services, config)

      // The foreign row survives even though its directory is gone.
      expect(
        (await run(services.db.listWorktrees("git-project"))).map((worktree) => worktree.id)
      ).toContain(foreign.id)

      // A worktree whose directory vanished makes `git worktree remove` fail;
      // the sweep must keep going and still clear the rest.
      rmSync(stubborn.path, { recursive: true, force: true })
      const project = (await run(services.db.listProjects)).find(
        (candidate) => candidate.id === "git-project"
      )!
      await discardProjectWorktrees(services, config.id, project)
      expect(await listSnapshotRefWorktreeIds(repoFolder)).toEqual([foreign.id])
    })
  })

  it("leaves an archive in flight alone while its files are still being removed", async () => {
    await withWorktreesRoot(async () => {
      const { services, repoFolder, makeWorktree, config } = await setUpProject()
      const worktree = await makeWorktree("bucatini")
      const parentSha = (await git(["rev-parse", "HEAD"], repoFolder)).stdout.trim()
      await run(
        services.db.createArchivedWorktree({
          id: worktree.id,
          projectId: "git-project",
          serverId: "server-a",
          originalName: worktree.name,
          branch: `codevisor/${worktree.name}`,
          parentSha,
          snapshotRef: snapshotRefFor(worktree.id),
          createdAt: new Date().toISOString(),
          state: "complete"
        })
      )
      // Files already gone but the `worktrees` row still present: the archive
      // pass owns this row, so the vanished-directory sweep must not race it.
      rmSync(worktree.path, { recursive: true, force: true })

      await reconcileWorktreeArchives(services, config)

      expect(
        (await run(services.db.listWorktrees("git-project"))).map((candidate) => candidate.id)
      ).toContain(worktree.id)
    })
  })

  it("ignores a project with no location on this server", async () => {
    await withWorktreesRoot(async () => {
      const { services } = await setUpProject()
      const project = (await run(services.db.listProjects)).find(
        (candidate) => candidate.id === "git-project"
      )!

      await expect(
        discardProjectWorktrees(services, "server-elsewhere", project)
      ).resolves.toBeUndefined()
    })
  })
})
