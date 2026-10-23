import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, Worktree } from "@codevisor/api"
import { runGit, snapshotRefFor } from "@codevisor/worktrees"
import Database from "better-sqlite3"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { archiveJobs } from "../archive-jobs.js"
import { jsonRequest, run, start, tempDirs, listSubjectEvents } from "../test-support.js"
import { field, idOf } from "./response-test-support.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })
const decodeWorktree = decode(Worktree)
const decodeRooted = decode(
  Schema.Struct({ isArchived: Schema.Boolean, rootDirectory: Schema.String })
)
const decodeChatCwd = decode(Schema.Struct({ session: Schema.Struct({ cwd: Schema.String }) }))
const decodeKeptArtifacts = decode(Schema.UndefinedOr(Schema.Array(Schema.String)))

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

const setUpGitProjects = async () => {
  const { agents, server, services } = await start()
  const serverDirectory = tempDirs.at(-1)
  if (serverDirectory === undefined) throw new Error("missing server directory")
  const serverDatabasePath = join(serverDirectory, "codevisor.sqlite")
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
    decode(Schema.Array(Worktree))(
      (await jsonRequest(server, "/v1/projects/git-project/worktrees")).body
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
    await withWorktreesRoot(async (worktreesRoot) => {
      const { server, services, repoFolder, worktreeNames } = await setUpGitProjects()

      const makeWorkspace = async (id: string, name: string, chats = 1) => {
        const worktree = decodeWorktree(
          (
            await jsonRequest(server, "/v1/projects/git-project/worktrees", {
              body: JSON.stringify({ name }),
              method: "POST"
            })
          ).body
        )
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
            idOf(
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
              ).body
            )
          )
        }
        return { worktree, sessions }
      }
      const setArchived = async (id: string, isArchived: boolean) => {
        const response = await jsonRequest(server, `/v1/workspaces/${id}`, {
          body: JSON.stringify({ isArchived }),
          method: "PATCH"
        })
        await archiveJobs(services).idle()
        return response
      }

      const { worktree: solo, sessions: soloChats } = await makeWorkspace("solo-ws", "solo work", 2)
      expect(existsSync(solo.path)).toBe(true)

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

      await setArchived("sharer-ws", true)
      expect(existsSync(solo.path)).toBe(false)
      expect(await worktreeNames()).not.toContain(solo.name)
      expect(
        (await run(services.db.listArchivedWorktrees("git-project"))).find(
          (archived) => archived.originalName === solo.name
        )?.state
      ).toBe("complete")

      expect((await setArchived("sharer-ws", true)).status).toBe(200)

      const restored = decodeRooted((await setArchived("solo-ws", false)).body)
      expect(restored.isArchived).toBe(false)
      expect(restored.rootDirectory).toBe(solo.path)
      expect(existsSync(solo.path)).toBe(true)
      expect(await worktreeNames()).toContain(solo.name)
      const rejoined = decodeChatCwd(
        (await jsonRequest(server, `/v1/sessions/${soloChats[0]}`)).body
      )
      expect(rejoined.session.cwd).toBe(solo.path)

      const { worktree: ignoredTree, sessions: ignoredChats } = await makeWorkspace(
        "ignored-ws",
        "with ignored",
        2
      )
      writeFileSync(join(ignoredTree.path, ".gitignore"), ".env\ntmp/\nnode_modules/\n")
      writeFileSync(join(ignoredTree.path, ".env"), "SECRET=1\n")
      mkdirSync(join(ignoredTree.path, "tmp"))
      writeFileSync(join(ignoredTree.path, "tmp", "shot.png"), "pixels")
      mkdirSync(join(ignoredTree.path, "node_modules"))
      writeFileSync(join(ignoredTree.path, "node_modules", "junk.js"), "junk\n")
      await setArchived("ignored-ws", true)
      const keptFolder = join(worktreesRoot, ".archived-artifacts.noindex", ignoredTree.id)
      expect(readFileSync(join(keptFolder, "tmp", "shot.png"), "utf8")).toBe("pixels")
      expect(existsSync(join(keptFolder, "node_modules"))).toBe(false)
      expect(
        listSubjectEvents(services, "ignored-ws").map((event) =>
          decodeKeptArtifacts(field(event.payload, "archiveKeptArtifacts"))
        )
      ).toContainEqual([".env", "tmp/"])

      const squatter = decodeWorktree(
        (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            body: JSON.stringify({ name: ignoredTree.name }),
            method: "POST"
          })
        ).body
      )
      expect(squatter.name).toBe(ignoredTree.name)
      const suffixed = decodeRooted((await setArchived("ignored-ws", false)).body)
      expect(suffixed.rootDirectory).not.toBe(squatter.path)
      expect(suffixed.rootDirectory).not.toBe(ignoredTree.path)
      expect(existsSync(suffixed.rootDirectory)).toBe(true)
      expect(readFileSync(join(suffixed.rootDirectory, "tmp", "shot.png"), "utf8")).toBe("pixels")
      expect(readFileSync(join(suffixed.rootDirectory, ".env"), "utf8")).toBe("SECRET=1\n")
      expect(existsSync(keptFolder)).toBe(false)
      for (const chatId of ignoredChats) {
        const chat = decodeChatCwd((await jsonRequest(server, `/v1/sessions/${chatId}`)).body)
        expect(chat.session.cwd).toBe(suffixed.rootDirectory)
      }

      const { worktree: orphanTree } = await makeWorkspace("orphan-ws", "orphan")
      await setArchived("orphan-ws", true)
      await run(services.db.deleteArchivedWorktree(orphanTree.id))
      expect((await setArchived("orphan-ws", false)).body).toMatchObject({ isArchived: false })
      expect(
        listSubjectEvents(services, "orphan-ws").some(
          (event) => field(event.payload, "archiveRestoreIncomplete") === true
        )
      ).toBe(true)

      const { worktree: strayTree } = await makeWorkspace("stray-ws", "stray")
      await run(services.db.deleteWorktree(strayTree.id))
      expect((await setArchived("stray-ws", true)).body).toMatchObject({ isArchived: true })

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

      const { worktree: prunedTree } = await makeWorkspace("pruned-ws", "pruned")
      await setArchived("pruned-ws", true)
      await runGit("drop-snapshot", ["update-ref", "-d", snapshotRefFor(prunedTree.id)], repoFolder)
      const prunedBack = await setArchived("pruned-ws", false)
      expect(prunedBack.body).toMatchObject({ isArchived: false })
      expect(
        listSubjectEvents(services, "pruned-ws").some(
          (event) => field(event.payload, "archiveRestoreIncomplete") === true
        )
      ).toBe(true)

      await jsonRequest(server, "/v1/workspaces/plain-ws", {
        body: JSON.stringify({ projectId: "git-project", name: "plain", hasCustomName: false }),
        method: "PUT"
      })
      const before = (await worktreeNames()).length
      await setArchived("plain-ws", true)
      expect((await worktreeNames()).length).toBe(before)
    })
  })

  it("keeps a worktree from before the .noindex layout in its folder across archive and restore", async () => {
    await withWorktreesRoot(async (worktreesRoot) => {
      const { server, services, repoFolder } = await setUpGitProjects()
      const legacyPath = join(worktreesRoot, "git-project", "udon")
      await git(["worktree", "add", "-b", "codevisor/udon", legacyPath], repoFolder)
      const worktree = await run(
        services.db.createWorktree("git-project", "udon", "codevisor/udon")
      )
      expect(worktree.path).toBe(legacyPath)
      await jsonRequest(server, "/v1/workspaces/udon-ws", {
        body: JSON.stringify({
          projectId: "git-project",
          name: "udon",
          hasCustomName: false,
          rootDirectory: legacyPath
        }),
        method: "PUT"
      })
      const chatId = idOf(
        (
          await jsonRequest(server, "/v1/sessions", {
            body: JSON.stringify({
              projectId: "git-project",
              workspaceId: "udon-ws",
              harnessId: "codex",
              worktreeName: "udon"
            }),
            method: "POST"
          })
        ).body
      )
      const setArchived = async (isArchived: boolean) => {
        const response = await jsonRequest(server, "/v1/workspaces/udon-ws", {
          body: JSON.stringify({ isArchived }),
          method: "PATCH"
        })
        await archiveJobs(services).idle()
        return response
      }

      await setArchived(true)
      expect(existsSync(legacyPath)).toBe(false)

      const restored = decodeRooted((await setArchived(false)).body)
      expect(restored.rootDirectory).toBe(legacyPath)
      expect(existsSync(legacyPath)).toBe(true)
      expect(existsSync(join(worktreesRoot, "worktrees.noindex", "git-project", "udon"))).toBe(
        false
      )
      const chat = decodeChatCwd((await jsonRequest(server, `/v1/sessions/${chatId}`)).body)
      expect(chat.session.cwd).toBe(legacyPath)
    })
  })

  it("rejects sessions whose worktree or project folder is unavailable", async () => {
    await withWorktreesRoot(async () => {
      const { repoFolder, repoRoot, server, serverDatabasePath } = await setUpGitProjects()
      const worktree = decodeWorktree(
        (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            body: JSON.stringify({ name: "fix-auth" }),
            method: "POST"
          })
        ).body
      )
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
      expect(field(missingFolder.body, "error")).toContain("Worktree folder does not exist")

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
      expect(field(detached.body, "error")).toContain("no folder on this machine")

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
