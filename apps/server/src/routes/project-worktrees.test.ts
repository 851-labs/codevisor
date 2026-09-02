import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"
import { describe, expect, it } from "vitest"
import { productionFoodWorktreeNames } from "@codevisor/worktrees"
import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"

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

describe("project worktree routes", () => {
  it("creates worktrees with setup events, readable names, and worktree sessions", async () => {
    await withWorktreesRoot(async (worktreesRoot) => {
      const { agents, repoFolder, server, services } = await setUpGitProjects()
      // Worktree creation on a non-git project is refused.
      expect(
        (
          await jsonRequest(server, "/v1/projects/plain-project/worktrees", {
            body: JSON.stringify({ name: "nope" }),
            method: "POST"
          })
        ).status
      ).toBe(422)

      // A client-supplied id keys the worktree row and its setup events so
      // callers can follow progress while the create request is in flight.
      const worktreeResponse = await jsonRequest(server, "/v1/projects/git-project/worktrees", {
        body: JSON.stringify({
          id: "wt-fix-auth",
          name: "Fix Auth!",
          sessionId: "session-awaiting-worktree"
        }),
        method: "POST"
      })
      expect(worktreeResponse.status).toBe(201)
      const worktree = worktreeResponse.body as {
        readonly id: string
        readonly name: string
        readonly branch: string
        readonly path: string
      }
      expect(worktree).toMatchObject({
        id: "wt-fix-auth",
        projectId: "git-project",
        serverId: "server-a"
      })
      // A custom name stays clean when it is available.
      expect(worktree.name).toBe("fix-auth")
      expect(worktree.branch).toBe(`codevisor/${worktree.name}`)
      expect(worktree.path).toBe(join(worktreesRoot, "git-project", worktree.name))
      expect(existsSync(join(worktree.path, ".git"))).toBe(true)

      // Setup progress was streamed as ordered worktree.setup events: started,
      // git output lines (git narrates "Preparing worktree ..." on stderr),
      // then completed with the elapsed duration.
      const setupPayloads = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-fix-auth")
        .map(
          (event) =>
            event.payload as {
              readonly state: string
              readonly stream?: string
              readonly line?: string
              readonly durationMs?: number
            }
        )
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
      const mirroredSetupPayloads = (await run(services.db.listEvents(0))).filter(
        (event) =>
          event.kind === "worktree.setup" && event.subjectId === "session-awaiting-worktree"
      )
      expect(
        mirroredSetupPayloads.map((event) => (event.payload as { state: string }).state)
      ).toEqual(setupPayloads.map((payload) => payload.state))
      const mirroredSetupHistory = (
        await jsonRequest(server, "/v1/sessions/session-awaiting-worktree/events")
      ).body as ReadonlyArray<{ readonly kind: string; readonly subjectId: string }>
      expect(mirroredSetupHistory).toHaveLength(mirroredSetupPayloads.length)
      expect(mirroredSetupHistory.every((event) => event.kind === "worktree.setup")).toBe(true)

      // Repeated custom names get a readable sequence number.
      const secondWorktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(secondWorktree.name).toBe("fix-auth-2")
      expect(secondWorktree.branch).toBe(`codevisor/${secondWorktree.name}`)
      const thirdWorktree = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          body: JSON.stringify({ name: "fix auth" }),
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(thirdWorktree.name).toBe("fix-auth-3")
      expect(thirdWorktree.branch).toBe(`codevisor/${thirdWorktree.name}`)
      // Missing names get a compact food word from the curated production pool.
      const randomNamed = (
        await jsonRequest(server, "/v1/projects/git-project/worktrees", {
          method: "POST"
        })
      ).body as { readonly name: string; readonly branch: string }
      expect(productionFoodWorktreeNames).toContain(randomNamed.name)
      expect(randomNamed.branch).toBe(`codevisor/${randomNamed.name}`)
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(4)

      // Git refs outlive archived database rows and are shared by isolated
      // development servers. A stale branch is included in allocation, so
      // the request transparently moves to the next readable name.
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
      const recoveredSetup = (await run(services.db.listEvents(0)))
        .filter((event) => event.kind === "worktree.setup" && event.subjectId === "wt-doomed")
        .map((event) => (event.payload as { readonly state: string }).state)
      expect(recoveredSetup[0]).toBe("started")
      expect(recoveredSetup.at(-1)).toBe("completed")
      expect(recoveredSetup).not.toContain("failed")
      expect(
        ((await jsonRequest(server, "/v1/projects/git-project/worktrees")).body as Array<unknown>)
          .length
      ).toBe(5)

      // Sessions created with a worktree run the agent inside the worktree.
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
      const session = sessionResponse.body as {
        readonly id: string
        readonly agentSessionId: string
        readonly cwd: string
        readonly worktreeName: string
      }
      expect(session.worktreeName).toBe(worktree.name)
      expect(session.cwd).toBe(worktree.path)
      expect(agents.creations).toContainEqual(["codex", worktree.path])
      const sessionHistory = (await jsonRequest(server, `/v1/sessions/${session.id}/events`))
        .body as ReadonlyArray<{ readonly kind: string; readonly subjectId: string }>
      expect(sessionHistory).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ kind: "worktree.setup", subjectId: worktree.id })
        ])
      )

      // Reattaching (prompt after restart) resolves the same worktree cwd.
      await jsonRequest(server, `/v1/sessions/${session.id}/prompt`, {
        body: JSON.stringify({ text: "hello worktree" }),
        method: "POST"
      })
      await waitFor(() => agents.prompts.some((prompt) => prompt[1] === "hello worktree"))
      expect(agents.loads).toContainEqual(["codex", session.agentSessionId, worktree.path])
    })
  })
})
