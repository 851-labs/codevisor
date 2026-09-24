import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { runGit, snapshotRefFor } from "@codevisor/worktrees"
import Database from "better-sqlite3"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })

/// Points the server at a fresh worktrees root for the duration of `body`.
const withWorktreesRoot = async <A>(body: (worktreesRoot: string) => Promise<A>): Promise<A> => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-worktrees-"))
  tempDirs.push(worktreesRoot)
  process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
  try {
    return await body(worktreesRoot)
  } finally {
    delete process.env["CODEVISOR_WORKTREES_ROOT"]
  }
}

/// A started server with one git-backed project (git-project) and one plain
/// folder project (plain-project).
const setUpGitProjects = async () => {
  const { agents, server, services } = await start()
  // makeServices' temp dir (the newest entry) holds the server database.
  const serverDatabasePath = join(tempDirs[tempDirs.length - 1] as string, "codevisor.sqlite")
  const repoRoot = mkdtempSync(join(tmpdir(), "codevisor-repo-"))
  tempDirs.push(repoRoot)
  const repoFolder = join(repoRoot, "repo")
  const plainFolder = join(repoRoot, "plain")
  mkdirSync(repoFolder)
  mkdirSync(plainFolder)
  await git(["init"], repoFolder)
  await git(
    ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "--allow-empty", "-m", "init"],
    repoFolder
  )
  const projectResponse = await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repoFolder, id: "git-project" }),
    method: "POST"
  })
  expect(projectResponse.status).toBe(201)
  expect(projectResponse.body).toMatchObject({
    id: "git-project",
    locations: [{ serverId: "server-a", folderPath: repoFolder, isGitRepository: true }]
  })
  const plainResponse = await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath: plainFolder, id: "plain-project" }),
    method: "POST"
  })
  expect(plainResponse.body).toMatchObject({ locations: [{ isGitRepository: false }] })
  const worktreeNames = async () =>
    (
      (await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as ReadonlyArray<{
        readonly name: string
      }>
    ).map((entry) => entry.name)
  return {
    agents,
    plainFolder,
    repoFolder,
    repoRoot,
    server,
    serverDatabasePath,
    services,
    worktreeNames
  }
}

describe("project worktree archive routes", () => {
  it("archives and restores the worktree its workspace owns", async () => {
    await withWorktreesRoot(async () => {
      const { server, services, repoFolder, worktreeNames } = await setUpGitProjects()

      /// A workspace anchored on a fresh worktree, plus `chats` chats in it.
      /// The workspace owns the directory, so archiving it is what reclaims
      /// the files.
      const makeWorkspace = async (id: string, name: string, chats = 1) => {
        const worktree = (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            body: JSON.stringify({ name }),
            method: "POST"
          })
        ).body as { readonly id: string; readonly name: string; readonly path: string }
        await jsonRequest(server, `/v1/workspaces/${id}`, {
          body: JSON.stringify({
            projectId: "git-project",
            name,
            hasCustomName: false,
            rootDirectory: worktree.path
          }),
          method: "PUT"
        })
        const sessions: Array<string> = []
        for (let index = 0; index < chats; index += 1) {
          sessions.push(
            (
              (
                await jsonRequest(server, "/v1/sessions", {
                  body: JSON.stringify({
                    projectId: "git-project",
                    workspaceId: id,
                    harnessId: "codex",
                    worktreeName: worktree.name
                  }),
                  method: "POST"
                })
              ).body as { readonly id: string }
            ).id
          )
        }
        return { worktree, sessions }
      }
      const setArchived = (id: string, isArchived: boolean) =>
        jsonRequest(server, `/v1/workspaces/${id}`, {
          body: JSON.stringify({ isArchived }),
          method: "PATCH"
        })

      const { worktree: solo, sessions: soloChats } = await makeWorkspace("solo-ws", "solo work", 2)
      expect(existsSync(solo.path)).toBe(true)

      // A second workspace sharing the same directory keeps it alive.
      await jsonRequest(server, "/v1/workspaces/sharer-ws", {
        body: JSON.stringify({
          projectId: "git-project",
          name: "sharer",
          hasCustomName: false,
          rootDirectory: solo.path
        }),
        method: "PUT"
      })
      await setArchived("solo-ws", true)
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)

      // Archiving the last workspace on that directory removes it from git and
      // disk, and records a completed archive that restore can navigate by.
      await setArchived("sharer-ws", true)
      expect(existsSync(solo.path)).toBe(false)
      expect(await worktreeNames()).not.toContain(solo.name)
      expect(
        (await run(services.db.listArchivedWorktrees("git-project"))).find(
          (archived) => archived.originalName === solo.name
        )?.state
      ).toBe("complete")

      // Re-archiving once the worktree record is gone is a harmless no-op.
      expect((await setArchived("sharer-ws", true)).status).toBe(200)

      // Restoring rebuilds the worktree from its snapshot and reclaims the
      // freed name, so every chat in the workspace resolves to its old cwd.
      const restored = (await setArchived("solo-ws", false)).body as {
        readonly isArchived: boolean
        readonly rootDirectory: string
      }
      expect(restored.isArchived).toBe(false)
      expect(restored.rootDirectory).toBe(solo.path)
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)
      const rejoined = (await jsonRequest(server, `/v1/sessions/${soloChats[0]}`)).body as {
        readonly session: { readonly cwd: string }
      }
      expect(rejoined.session.cwd).toBe(solo.path)

      // Gitignored files are not snapshotted — putting a .env into a git object
      // that may later be pushed is worse than losing it — so the client is
      // told exactly what went away with the worktree.
      const { worktree: ignoredTree, sessions: ignoredChats } = await makeWorkspace(
        "ignored-ws",
        "with ignored",
        2
      )
      writeFileSync(join(ignoredTree.path, ".gitignore"), ".env\n")
      writeFileSync(join(ignoredTree.path, ".env"), "SECRET=1\n")
      await setArchived("ignored-ws", true)
      const ignoredHistory = (await run(
        services.db.listSubjectEvents("ignored-ws")
      )) as ReadonlyArray<{
        readonly payload?: { readonly archiveDroppedIgnoredPaths?: ReadonlyArray<string> }
      }>
      expect(
        ignoredHistory.some((event) =>
          event.payload?.archiveDroppedIgnoredPaths?.some((path) => path.endsWith(".env"))
        )
      ).toBe(true)

      // The freed name is taken before the restore, so the workspace comes back
      // under a suffixed name rather than adopting the squatter's files.
      const squatter = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: ignoredTree.name }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      expect(squatter.name).toBe(ignoredTree.name)
      const suffixed = (await setArchived("ignored-ws", false)).body as {
        readonly rootDirectory: string
      }
      expect(suffixed.rootDirectory).not.toBe(squatter.path)
      expect(suffixed.rootDirectory).not.toBe(ignoredTree.path)
      expect(existsSync(suffixed.rootDirectory)).toBe(true)
      // Every chat in the workspace follows the rename, not just one, or the
      // others would resolve to a name nobody owns.
      for (const chatId of ignoredChats) {
        const chat = (await jsonRequest(server, `/v1/sessions/${chatId}`)).body as {
          readonly session: { readonly cwd: string }
        }
        expect(chat.session.cwd).toBe(suffixed.rootDirectory)
      }

      // A snapshot that has gone missing still restores — the chats matter more
      // than the files — but says so rather than pretending they came back.
      const { worktree: orphanTree } = await makeWorkspace("orphan-ws", "orphan")
      await setArchived("orphan-ws", true)
      await run(services.db.deleteArchivedWorktree(orphanTree.id))
      expect((await setArchived("orphan-ws", false)).body).toMatchObject({ isArchived: false })
      const orphanHistory = (await run(
        services.db.listSubjectEvents("orphan-ws")
      )) as ReadonlyArray<{
        readonly payload?: { readonly archiveRestoreIncomplete?: boolean }
      }>
      expect(orphanHistory.some((event) => event.payload?.archiveRestoreIncomplete === true)).toBe(
        true
      )

      // A workspace pointing at a worktree row that no longer exists archives
      // cleanly: there is nothing to snapshot, so it is a plain flag flip.
      const { worktree: strayTree } = await makeWorkspace("stray-ws", "stray")
      await run(services.db.deleteWorktree(strayTree.id))
      expect((await setArchived("stray-ws", true)).body).toMatchObject({ isArchived: true })

      // A directory that is not a Codevisor worktree path (the project folder
      // itself, or anything else a client pinned) has no name to look a
      // snapshot up by, so archive and restore are both no-ops on the files.
      for (const [id, rootDirectory] of [
        ["rooted-ws", repoFolder],
        ["relative-ws", "noslash"]
      ] as const) {
        await jsonRequest(server, `/v1/workspaces/${id}`, {
          body: JSON.stringify({
            projectId: "git-project",
            name: id,
            hasCustomName: false,
            rootDirectory
          }),
          method: "PUT"
        })
        await setArchived(id, true)
        expect((await setArchived(id, false)).body).toMatchObject({ isArchived: false })
      }
      expect(existsSync(repoFolder)).toBe(true)

      // A snapshot ref pruned out from under a recorded archive: the restore
      // rebuilds the worktree from the parent commit and must NOT delete a
      // record whose contents it could not apply.
      const { worktree: prunedTree } = await makeWorkspace("pruned-ws", "pruned")
      await setArchived("pruned-ws", true)
      await runGit("drop-snapshot", ["update-ref", "-d", snapshotRefFor(prunedTree.id)], repoFolder)
      const prunedBack = await setArchived("pruned-ws", false)
      expect(prunedBack.body).toMatchObject({ isArchived: false })
      const prunedHistory = (await run(
        services.db.listSubjectEvents("pruned-ws")
      )) as ReadonlyArray<{
        readonly payload?: { readonly archiveRestoreIncomplete?: boolean }
      }>
      expect(prunedHistory.some((event) => event.payload?.archiveRestoreIncomplete === true)).toBe(
        true
      )

      // A workspace that never had a worktree leaves every worktree intact.
      await jsonRequest(server, "/v1/workspaces/plain-ws", {
        body: JSON.stringify({ projectId: "git-project", name: "plain", hasCustomName: false }),
        method: "PUT"
      })
      const before = (await worktreeNames()).length
      await setArchived("plain-ws", true)
      expect((await worktreeNames()).length).toBe(before)
    })
  })

  it("rejects sessions whose worktree or project folder is unavailable", async () => {
    await withWorktreesRoot(async () => {
      const { repoFolder, repoRoot, server, serverDatabasePath } = await setUpGitProjects()
      const worktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix-auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      // A recorded worktree whose folder vanished is rejected too.
      rmSync(worktree.path, { force: true, recursive: true })
      await git(["worktree", "prune"], repoFolder)
      const missingFolder = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: worktree.name,
          title: "Missing worktree"
        }),
        method: "POST"
      })
      expect(missingFolder.status).toBe(400)
      expect((missingFolder.body as { readonly error: string }).error).toContain(
        "Worktree folder does not exist"
      )

      // A project whose only folder lives on another machine can't host
      // sessions here.
      await jsonRequest(server, "/v1/projects", {
        body: JSON.stringify({ folderPath: join(repoRoot, "detached"), id: "detached-project" }),
        method: "POST"
      })
      const sqlite = new Database(serverDatabasePath)
      sqlite
        .prepare("update project_locations set server_id = 'server-elsewhere' where project_id = ?")
        .run("detached-project")
      sqlite.close()
      const detached = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "detached-project", harnessId: "codex" }),
        method: "POST"
      })
      expect(detached.status).toBe(400)
      expect((detached.body as { readonly error: string }).error).toContain(
        "no folder on this machine"
      )

      // Unknown worktree names are rejected.
      expect(
        (
          await jsonRequest(server, "/v1/sessions", {
            body: JSON.stringify({
              projectId: "git-project",
              harnessId: "codex",
              worktreeName: "does-not-exist"
            }),
            method: "POST"
          })
        ).status
      ).toBe(400)
    })
  })
})
