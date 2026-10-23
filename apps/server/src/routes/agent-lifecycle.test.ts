import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { AgentArchiveResult, decode, Worktree } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { archiveJobs } from "../archive-jobs.js"
import { jsonRequest, listSubjectEvents, run, start, tempDirs } from "../test-support.js"
import { field, idOf } from "./response-test-support.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) =>
  execFileAsync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd })
const shell = { id: "task-1", description: "Monitor CI", status: "running", taskType: "shell" }

const withWorktreesRoot = async <A>(body: (worktreesRoot: string) => Promise<A>): Promise<A> => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-agent-worktrees-"))
  tempDirs.push(worktreesRoot)
  process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
  try {
    return await body(worktreesRoot)
  } finally {
    delete process.env["CODEVISOR_WORKTREES_ROOT"]
  }
}

const gitProject = async () => {
  const running = await start()
  const repo = join(mkdtempSync(join(tmpdir(), "codevisor-agent-repo-")), "repo")
  tempDirs.push(repo)
  mkdirSync(repo)
  await git(["init"], repo)
  writeFileSync(join(repo, ".gitignore"), "tmp/\n")
  await git(["add", ".gitignore"], repo)
  await git(["commit", "-m", "init"], repo)
  await jsonRequest(running.server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repo, id: "agent-project" }),
    method: "POST"
  })
  const worktree = async () =>
    decode(Worktree)(
      (
        await jsonRequest(running.server, "/v1/projects/agent-project/worktrees", {
          body: JSON.stringify({ name: "agent work" }),
          method: "POST"
        })
      ).body
    )
  const agentIn = async (worktreeName: string) =>
    idOf(
      (
        await jsonRequest(running.server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "agent-project",
            workspaceId: randomUUID(),
            harnessId: "codex",
            worktreeName
          }),
          method: "POST"
        })
      ).body
    )
  return { ...running, repo, worktree, agentIn }
}

describe("agent lifecycle routes", () => {
  it("counts an agent with a live background task as working in list and wait", async () => {
    const { server, services } = await start()
    const project = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({
            folderPath: mkdtempSync(join(tmpdir(), "codevisor-agent-plain-"))
          }),
          method: "POST"
        })
      ).body
    )
    const agentId = idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: project, harnessId: "codex" }),
          method: "POST"
        })
      ).body
    )
    await run(services.db.appendEvent("session.updated", agentId, { backgroundTasks: [shell] }))
    const wait = (until: ReadonlyArray<string>) =>
      jsonRequest(server, "/v1/agents/wait", {
        body: JSON.stringify({ agentIds: [agentId], until, timeoutMs: 0 }),
        method: "POST"
      })

    expect((await jsonRequest(server, "/v1/agents")).body).toMatchObject({
      items: [{ agentId, state: "working" }]
    })
    expect((await jsonRequest(server, "/v1/agents?state=idle")).body).toEqual({ items: [] })
    expect((await wait(["idle"])).body).toEqual({
      items: [{ agentId, state: "working" }],
      timedOut: true
    })
    expect((await wait(["working"])).body).toMatchObject({ timedOut: false })
    expect((await jsonRequest(server, "/v1/agents?state=busy")).status).toBe(400)
  })

  it("lists slim summaries filtered by project, parent, and label", async () => {
    await withWorktreesRoot(async () => {
      const { server, worktree } = await gitProject()
      const tree = await worktree()
      const create = async (fields: Record<string, unknown>) =>
        idOf(
          (
            await jsonRequest(server, "/v1/sessions", {
              body: JSON.stringify({ projectId: "agent-project", harnessId: "codex", ...fields }),
              method: "POST"
            })
          ).body
        )
      const parent = await create({})
      const child = await create({
        parentSessionId: parent,
        labels: { role: "worker" },
        worktreeName: tree.name,
        workspaceId: randomUUID(),
        updatedAt: "2026-10-23T00:00:00.000Z"
      })
      const list = async (query: string) => (await jsonRequest(server, `/v1/agents?${query}`)).body

      expect(await list(`parentAgentId=${parent.toUpperCase()}`)).toEqual({
        items: [
          {
            agentId: child,
            title: expect.any(String),
            state: "idle",
            projectId: "agent-project",
            harness: "codex",
            workspaceId: expect.any(String),
            worktreeName: tree.name,
            labels: { role: "worker" },
            parentAgentId: parent,
            updatedAt: expect.any(String)
          }
        ]
      })
      expect(await list("label=role=worker")).toMatchObject({ items: [{ agentId: child }] })
      expect(await list("project=elsewhere")).toEqual({ items: [] })
      expect(await list("project=AGENT-PROJECT")).toMatchObject({
        items: [{ agentId: parent }, { agentId: child }]
      })
    })
  })

  it("keeps an idle agent with queued messages unsettled and reports a pending question", async () => {
    const { server, services } = await start()
    const project = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({
            folderPath: mkdtempSync(join(tmpdir(), "codevisor-agent-wait-"))
          }),
          method: "POST"
        })
      ).body
    )
    const create = async () =>
      idOf(
        (
          await jsonRequest(server, "/v1/sessions", {
            body: JSON.stringify({ projectId: project, harnessId: "codex" }),
            method: "POST"
          })
        ).body
      )
    const queued = await create()
    const asking = await create()
    await run(services.db.createPromptQueueItem(queued, "next task"))
    const question = {
      sessionUpdate: "question",
      questionId: "q-1",
      questions: [{ id: "a", question: "Ship it?", options: [], allowsOther: true }]
    }
    await run(services.db.appendEvent("session.output", asking, question))
    const wait = (agentIds: ReadonlyArray<string>) =>
      jsonRequest(server, "/v1/agents/wait", {
        body: JSON.stringify({ agentIds, timeoutMs: 0 }),
        method: "POST"
      })

    expect((await wait([queued])).body).toEqual({
      items: [{ agentId: queued, state: "idle" }],
      timedOut: true
    })
    expect((await wait([asking])).body).toEqual({
      items: [{ agentId: asking, state: "waitingForUser", pendingQuestion: question }],
      timedOut: false
    })
  })

  it("refuses to archive an agent without a workspace", async () => {
    const { server } = await start()
    const project = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({
            folderPath: mkdtempSync(join(tmpdir(), "codevisor-agent-loose-"))
          }),
          method: "POST"
        })
      ).body
    )
    const agentId = idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({ projectId: project, harnessId: "codex" }),
          method: "POST"
        })
      ).body
    )

    expect(
      (await jsonRequest(server, `/v1/agents/${agentId}/archive`, { method: "POST" })).status
    ).toBe(422)
  })

  it("waits for an archive and reports the artifacts it kept", async () => {
    await withWorktreesRoot(async (worktreesRoot) => {
      const { server, worktree, agentIn } = await gitProject()
      const tree = await worktree()
      const agentId = await agentIn(tree.name)
      mkdirSync(join(tree.path, "tmp"))
      writeFileSync(join(tree.path, "tmp", "shot.png"), "pixels")

      const archived = await jsonRequest(server, `/v1/agents/${agentId}/archive`, {
        method: "POST"
      })

      expect(archived.body).toMatchObject({ agentId, archived: true, keptArtifacts: ["tmp/"] })
      expect(existsSync(tree.path)).toBe(false)
      expect(
        existsSync(join(worktreesRoot, ".archived-artifacts.noindex", tree.id, "tmp", "shot.png"))
      ).toBe(true)
    })
  })

  it("sets aside kept artifacts a restore couldn't put back, inside the worktree", async () => {
    await withWorktreesRoot(async (worktreesRoot) => {
      const { server, services, worktree, agentIn } = await gitProject()
      const tree = await worktree()
      const agentId = await agentIn(tree.name)
      mkdirSync(join(tree.path, "tmp"))
      writeFileSync(join(tree.path, "tmp", "shot.png"), "pixels")
      const { workspaceId } = decode(AgentArchiveResult)(
        (await jsonRequest(server, `/v1/agents/${agentId}/archive`, { method: "POST" })).body
      )
      const kept = join(worktreesRoot, ".archived-artifacts.noindex", tree.id)
      writeFileSync(join(kept, ".gitignore"), "kept copy\n")

      await jsonRequest(server, `/v1/workspaces/${workspaceId}`, {
        body: JSON.stringify({ isArchived: false }),
        method: "PATCH"
      })
      await archiveJobs(services).idle()

      const reported = listSubjectEvents(services, workspaceId).flatMap((event) => {
        const conflicts = field(event.payload, "archiveRestoreConflicts")
        return conflicts === undefined ? [] : [conflicts]
      })
      expect(reported).toEqual([[".codevisor-restore-conflicts/.gitignore-2"]])
      expect(existsSync(kept)).toBe(false)
      expect(
        readFileSync(join(tree.path, ".codevisor-restore-conflicts", ".gitignore-2"), "utf8")
      ).toBe("kept copy\n")
      expect(existsSync(join(tree.path, "tmp", "shot.png"))).toBe(true)
    })
  })

  it("fails the archive call when the archive fails, leaving the checkout in place", async () => {
    await withWorktreesRoot(async () => {
      const { server, worktree, agentIn } = await gitProject()
      const tree = await worktree()
      const agentId = await agentIn(tree.name)
      rmSync(join(tree.path, ".git"))

      const archived = await jsonRequest(server, `/v1/agents/${agentId}/archive`, {
        method: "POST"
      })

      expect(archived.status).toBeGreaterThanOrEqual(400)
      expect(existsSync(tree.path)).toBe(true)
    })
  })
})
