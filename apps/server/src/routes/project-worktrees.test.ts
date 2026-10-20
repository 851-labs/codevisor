import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, SessionSummary, Worktree, WorktreeSetupUpdate } from "@codevisor/api"
import { productionFoodWorktreeNames } from "@codevisor/worktrees"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs, waitFor, listEvents } from "../test-support.js"
import { itemsOf } from "./response-test-support.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })
const decodeWorktree = decode(Worktree)
const decodeSetup = decode(WorktreeSetupUpdate)

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

describe("project worktree routes", () => {
  it("skips names a remote already has as Codevisor branches", async () => {
    await withWorktreesRoot(async () => {
      const { repoFolder, server } = await setUpGitProjects()
      await git(["update-ref", "refs/remotes/origin/codevisor/pushed", "HEAD"], repoFolder)

      const created = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ name: "pushed" }),
        method: "POST"
      })

      expect(created.body).toMatchObject({ name: "pushed-2", branch: "codevisor/pushed-2" })
    })
  })

  it("creates worktrees with setup events, readable names, and worktree sessions", async () => {
    await withWorktreesRoot(async (worktreesRoot) => {
      const { agents, repoFolder, server, services } = await setUpGitProjects()
      expect(
        (
          await jsonRequest(server, "/v1/projects/plain-project/worktrees", {
            body: JSON.stringify({ name: "nope" }),
            method: "POST"
          })
        ).status
      ).toBe(422)

      const worktreeResponse = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({
          id: "wt-fix-auth",
          name: "Fix Auth!",
          sessionId: "session-awaiting-worktree"
        }),
        method: "POST"
      })
      expect(worktreeResponse.status).toBe(201)
      const worktree = decodeWorktree(worktreeResponse.body)
      expect(worktree).toMatchObject({
        id: "wt-fix-auth",
        projectId: "git-project",
        serverId: "server-a"
      })
      expect(worktree.name).toBe("fix-auth")
      expect(worktree.branch).toBe(`codevisor/${worktree.name}`)
      expect(worktree.path).toBe(join(worktreesRoot, "git-project", worktree.name))
      expect(existsSync(join(worktree.path, ".git"))).toBe(true)

      const setupPayloads = listEvents(services)
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-fix-auth")
        .map((event) => decodeSetup(event.payload))
      expect(setupPayloads[0]).toMatchObject({
        state: "started",
        worktreeId: "wt-fix-auth",
        projectId: "git-project",
        name: worktree.name,
        branch: worktree.branch
      })
      const logPayloads = setupPayloads.filter((payload) => payload.state === "log")
      expect(logPayloads.length).toBeGreaterThan(0)
      expect(logPayloads.every((payload) => (payload.line ?? "").length > 0)).toBe(true)
      expect(
        logPayloads.every((payload) => payload.stream === "stdout" || payload.stream === "stderr")
      ).toBe(true)
      const lastSetup = setupPayloads[setupPayloads.length - 1]
      expect(lastSetup?.state).toBe("completed")
      expect(lastSetup?.durationMs).toBeGreaterThanOrEqual(0)
      const mirroredSetupPayloads = listEvents(services).filter(
        (event) =>
          event.kind === "worktree.setup" && event.subjectId === "session-awaiting-worktree"
      )
      expect(mirroredSetupPayloads.map((event) => decodeSetup(event.payload).state)).toEqual(
        setupPayloads.map((payload) => payload.state)
      )
      expect(
        (await jsonRequest(server, "/v1/sessions/session-awaiting-worktree/events")).status
      ).toBe(410)

      const secondWorktree = decodeWorktree(
        (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            body: JSON.stringify({ name: "fix auth" }),
            method: "POST"
          })
        ).body
      )
      expect(secondWorktree.name).toBe("fix-auth-2")
      expect(secondWorktree.branch).toBe(`codevisor/${secondWorktree.name}`)
      const thirdWorktree = decodeWorktree(
        (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            body: JSON.stringify({ name: "fix auth" }),
            method: "POST"
          })
        ).body
      )
      expect(thirdWorktree.name).toBe("fix-auth-3")
      expect(thirdWorktree.branch).toBe(`codevisor/${thirdWorktree.name}`)
      const randomNamed = decodeWorktree(
        (
          await jsonRequest(server, "/v1/projects/git-project/worktrees", {
            method: "POST"
          })
        ).body
      )
      expect(productionFoodWorktreeNames).toContain(randomNamed.name)
      expect(randomNamed.branch).toBe(`codevisor/${randomNamed.name}`)
      expect(
        itemsOf((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body).length
      ).toBe(4)

      await git(["branch", "codevisor/doomed"], repoFolder)
      const recovered = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({ id: "wt-doomed", name: "doomed" }),
        method: "POST"
      })
      expect(recovered.status).toBe(201)
      expect(recovered.body).toMatchObject({
        id: "wt-doomed",
        name: "doomed-2",
        branch: "codevisor/doomed-2"
      })
      const recoveredSetup = listEvents(services)
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-doomed")
        .map((event) => decodeSetup(event.payload).state)
      expect(recoveredSetup[0]).toBe("started")
      expect(recoveredSetup.at(-1)).toBe("completed")
      expect(recoveredSetup).not.toContain("failed")
      expect(
        itemsOf((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body).length
      ).toBe(5)

      const sessionResponse = await jsonRequest(server, "/v1/sessions", {
        body: JSON.stringify({
          projectId: "git-project",
          harnessId: "codex",
          worktreeName: worktree.name,
          title: "Worktree chat"
        }),
        method: "POST"
      })
      expect(sessionResponse.status).toBe(201)
      const session = decode(SessionSummary)(sessionResponse.body)
      expect(session.worktreeName).toBe(worktree.name)
      expect(session.cwd).toBe(worktree.path)
      expect(agents.creations).toContainEqual(["codex", worktree.path])
      const page = await run(services.db.getTranscriptPage(session.id, undefined, 8))
      expect(page.setupActivities).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: "worktree.setup", subjectId: worktree.id })
        ])
      )

      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "hello worktree" }),
        method: "POST"
      })
      await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello worktree"))
      expect(agents.loads).toContainEqual(["codex", session.agentSessionId, worktree.path])
    })
  })
})
