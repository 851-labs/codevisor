import Database from "better-sqlite3"
import { Effect } from "effect"
import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import { jsonRequest, start, tempDirs } from "../test-support.js"

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
  it("archives and restores worktrees together with their sessions", async () => {
    await withWorktreesRoot(async () => {
      const { server, services, worktreeNames } = await setUpGitProjects()
      // Archiving a session deletes its worktree from disk once no active
      // session still relies on it. Set up a dedicated worktree shared by two
      // sessions plus an unrelated session in another project.
      await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "plain-project", harnessId: "codex" }),
        method: "POST"
      })
      const solo = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "solo work" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      expect(existsSync(solo.path)).toBe(true)
      const soloSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: solo.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const sharer = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: solo.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }

      // The worktree survives while another active session still uses it.
      await jsonRequest(server, `/v1/sessions/${soloSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)

      // Archiving the final active session removes it from git and disk.
      await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(existsSync(solo.path)).toBe(false)
      expect(await worktreeNames()).not.toContain(solo.name)
      const removedWorktreeHistory = (await jsonRequest(server, `/v1/sessions/${sharer.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string }>
      expect(removedWorktreeHistory.some((event) => event.kind === "worktree.setup")).toBe(false)

      // Re-archiving once the worktree record is gone is a harmless no-op.
      expect(
        (
          await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
            body: JSON.stringify({ isArchived: true }),
            method: "PATCH"
          })
        ).status
      ).toBe(200)

      // Unarchiving rebuilds the worktree from its snapshot and reclaims the
      // freed name, so the restored chat resolves to the same cwd as before.
      const restored = (
        await jsonRequest(server, `/v1/sessions/${sharer.id}`, {
          body: JSON.stringify({ isArchived: false }),
          method: "PATCH"
        })
      ).body as {
        readonly worktreeName: string
        readonly cwd: string
        readonly isArchived: boolean
      }
      expect(restored.isArchived).toBe(false)
      expect(restored.worktreeName).toBe(solo.name)
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)
      expect(restored.cwd).toBe(solo.path)

      // The restore is announced as its own event kind: clients must move the
      // row between sidebar sections, not just repaint it.
      const restoreHistory = (await jsonRequest(server, `/v1/sessions/${sharer.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string }>
      expect(restoreHistory.some((event) => event.kind === "session.unarchived")).toBe(true)

      // The other session that shared the worktree is still archived, and
      // unarchiving it now simply reattaches to the live worktree.
      const rejoined = (
        await jsonRequest(server, `/v1/sessions/${soloSession.id}`, {
          body: JSON.stringify({ isArchived: false }),
          method: "PATCH"
        })
      ).body as { readonly worktreeName: string; readonly cwd: string }
      expect(rejoined.worktreeName).toBe(solo.name)
      expect(rejoined.cwd).toBe(solo.path)
      expect(await worktreeNames()).toContain(solo.name)

      // Gitignored files are not snapshotted — putting a .env into a git
      // object that may later be pushed is worse than losing it — so the
      // client is told exactly what went away with the worktree.
      const ignoredTree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "with ignored" }),
          method: "POST"
        })
      ).body as { readonly id: string; readonly name: string; readonly path: string }
      writeFileSync(join(ignoredTree.path, ".gitignore"), ".env\n")
      writeFileSync(join(ignoredTree.path, ".env"), "SECRET=1\n")
      const ignoredSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: ignoredTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      // A second chat in the same worktree: when the restore has to rename,
      // every chat pointing at the old name must follow it, not just the one
      // being unarchived.
      const ignoredSibling = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: ignoredTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      await jsonRequest(server, `/v1/sessions/${ignoredSibling.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      await jsonRequest(server, `/v1/sessions/${ignoredSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      const ignoredHistory = (await jsonRequest(server, `/v1/sessions/${ignoredSession.id}/events`))
        .body as ReadonlyArray<{
        readonly kind: string
        readonly payload?: { readonly archiveDroppedIgnoredPaths?: ReadonlyArray<string> }
      }>
      expect(
        ignoredHistory.some((event) =>
          event.payload?.archiveDroppedIgnoredPaths?.some((path) => path.endsWith(".env"))
        )
      ).toBe(true)

      // The freed name is taken by a new worktree before the restore, so the
      // chat comes back under a suffixed name rather than colliding.
      const squatter = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: ignoredTree.name }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly path: string }
      expect(squatter.name).toBe(ignoredTree.name)
      const suffixed = (
        await jsonRequest(server, `/v1/sessions/${ignoredSession.id}`, {
          body: JSON.stringify({ isArchived: false }),
          method: "PATCH"
        })
      ).body as { readonly worktreeName: string; readonly cwd: string }
      // Restored under its own name plus a suffix, and — critically — into
      // its own directory rather than adopting the squatter's.
      expect(suffixed.worktreeName).not.toBe(ignoredTree.name)
      expect(suffixed.worktreeName.startsWith(ignoredTree.name)).toBe(true)
      expect(suffixed.cwd).not.toBe(squatter.path)
      expect(existsSync(suffixed.cwd)).toBe(true)
      // The sibling's pointer was rewritten too, so unarchiving it later finds
      // the worktree under its new name instead of a name nobody owns.
      const siblingAfterRename = (await jsonRequest(server, `/v1/sessions/${ignoredSibling.id}`))
        .body as { readonly session: { readonly worktreeName: string } }
      expect(siblingAfterRename.session.worktreeName).toBe(suffixed.worktreeName)

      // A snapshot that has gone missing (an archive predating snapshots, or a
      // pruned ref) still unarchives — the chat is what matters — but says so
      // rather than pretending the files came back.
      const orphanTree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "orphan" }),
          method: "POST"
        })
      ).body as { readonly id: string; readonly name: string }
      const orphanSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: orphanTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      await jsonRequest(server, `/v1/sessions/${orphanSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      await Effect.runPromise(services.db.deleteArchivedWorktree(orphanTree.id))
      const orphanRestored = await jsonRequest(server, `/v1/sessions/${orphanSession.id}`, {
        body: JSON.stringify({ isArchived: false }),
        method: "PATCH"
      })
      expect(orphanRestored.body).toMatchObject({ isArchived: false })
      const orphanHistory = (await jsonRequest(server, `/v1/sessions/${orphanSession.id}/events`))
        .body as ReadonlyArray<{
        readonly payload?: { readonly archiveRestoreIncomplete?: boolean }
      }>
      expect(orphanHistory.some((event) => event.payload?.archiveRestoreIncomplete === true)).toBe(
        true
      )

      // A chat pointing at a worktree row that no longer exists archives
      // cleanly: there is nothing to snapshot, so it is a plain flag flip.
      const strayTree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "stray" }),
          method: "POST"
        })
      ).body as { readonly id: string; readonly name: string }
      const straySession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "git-project",
            harnessId: "codex",
            worktreeName: strayTree.name
          }),
          method: "POST"
        })
      ).body as { readonly id: string }
      await Effect.runPromise(services.db.deleteWorktree(strayTree.id))
      const strayArchived = await jsonRequest(server, `/v1/sessions/${straySession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
      expect(strayArchived.body).toMatchObject({ isArchived: true })

      // Archiving a session that never had a worktree leaves worktrees intact.
      const plainSession = (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: "git-project", harnessId: "codex" }),
          method: "POST"
        })
      ).body as { readonly id: string }
      const before = (await worktreeNames()).length
      await jsonRequest(server, `/v1/sessions/${plainSession.id}`, {
        body: JSON.stringify({ isArchived: true }),
        method: "PATCH"
      })
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
