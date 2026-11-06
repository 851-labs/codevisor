import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, WorktreeSetupStatus } from "@codevisor/api"
import { afterEach, beforeEach, describe, expect, it } from "vitest"

import { jsonRequest, listEvents, start, tempDirs } from "../test-support.js"
import { itemsOf } from "./response-test-support.js"
import { worktreeSetupsIdle } from "./worktree-setup-jobs.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) => execFileAsync("git", [...args], { cwd })
const decodeStatus = decode(WorktreeSetupStatus)

let worktreesRoot = ""

beforeEach(() => {
  worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-worktree-setups-"))
  tempDirs.push(worktreesRoot)
  process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
})

afterEach(() => {
  delete process.env["CODEVISOR_WORKTREES_ROOT"]
})

const startWithProjects = async () => {
  const started = await start()
  const repoRoot = mkdtempSync(join(tmpdir(), "codevisor-setup-repo-"))
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
  await addProject(started.server, "git-project", repoFolder)
  await addProject(started.server, "plain-project", plainFolder)
  return started
}

const addProject = async (
  server: Awaited<ReturnType<typeof start>>["server"],
  id: string,
  folderPath: string
): Promise<void> => {
  const response = await jsonRequest(server, "/v1/projects", {
    body: JSON.stringify({ folderPath, id }),
    method: "POST"
  })
  expect(response.status).toBe(201)
}

const startSetup = (
  server: Awaited<ReturnType<typeof start>>["server"],
  body: Record<string, string>,
  projectId = "git-project"
) =>
  jsonRequest(server, `/v1/projects/${projectId}/worktree-setups`, {
    body: JSON.stringify(body),
    method: "POST"
  })

const setupStatus = async (
  server: Awaited<ReturnType<typeof start>>["server"],
  worktreeId: string
) => jsonRequest(server, `/v1/projects/git-project/worktree-setups/${worktreeId}`)

describe("worktree setup jobs", () => {
  it("answers at once while git checks out, then reports the finished worktree", async () => {
    const { server, services } = await startWithProjects()

    const started = await startSetup(server, { id: "wt-slow", name: "Slow Repo" })
    expect(started.status).toBe(202)
    expect(decodeStatus(started.body)).toEqual({ worktreeId: "wt-slow", state: "running" })

    await worktreeSetupsIdle(services)
    const finished = decodeStatus((await setupStatus(server, "wt-slow")).body)
    expect(finished).toMatchObject({
      worktreeId: "wt-slow",
      state: "completed",
      worktree: { id: "wt-slow", name: "slow-repo", branch: "codevisor/slow-repo" }
    })
    expect(existsSync(join(finished.worktree!.path, ".git"))).toBe(true)
    const created = listEvents(services).filter(
      (event) => event.kind === "worktree.created" && event.subjectId === "wt-slow"
    )
    expect(created).toHaveLength(1)
  })

  it("returns the same worktree when the same setup is started again", async () => {
    const { server, services } = await startWithProjects()

    const [first, second] = await Promise.all([
      startSetup(server, { id: "wt-retry", name: "retry" }),
      startSetup(server, { id: "wt-retry", name: "retry" })
    ])
    expect(first.status).toBe(202)
    expect(second.status).toBe(202)
    await worktreeSetupsIdle(services)

    const again = await startSetup(server, { id: "wt-retry", name: "retry" })
    expect(decodeStatus(again.body)).toMatchObject({
      state: "completed",
      worktree: { id: "wt-retry", name: "retry" }
    })
    const worktrees = itemsOf(
      (await jsonRequest(server, "/v1/projects/git-project/worktrees")).body
    )
    expect(worktrees).toHaveLength(1)
  })

  it("refuses a folder that is not a git repository before starting", async () => {
    const { server } = await startWithProjects()

    const refused = await startSetup(server, { id: "wt-plain" }, "plain-project")

    expect(refused.status).toBe(422)
    expect((await setupStatus(server, "wt-plain")).status).toBe(404)
  })

  it("reports a failed checkout with git's reason", async () => {
    const { server, services } = await startWithProjects()
    const blocked = join(worktreesRoot, "worktrees.noindex", "git-project", "blocked")
    mkdirSync(blocked, { recursive: true })
    writeFileSync(join(blocked, "keep.txt"), "in the way")

    const started = await startSetup(server, { id: "wt-blocked", name: "blocked" })
    expect(started.status).toBe(202)
    await worktreeSetupsIdle(services)

    const status = decodeStatus((await setupStatus(server, "wt-blocked")).body)
    expect(status.state).toBe("failed")
    expect(status.message).toContain("already exists")
    const worktrees = itemsOf(
      (await jsonRequest(server, "/v1/projects/git-project/worktrees")).body
    )
    expect(worktrees).toHaveLength(0)
  })

  it("does not know a setup that never started", async () => {
    const { server } = await startWithProjects()

    expect((await setupStatus(server, "wt-unknown")).status).toBe(404)
  })
})
