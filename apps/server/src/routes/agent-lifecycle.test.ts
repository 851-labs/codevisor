import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, Worktree } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest, run, start, tempDirs } from "../test-support.js"
import { idOf } from "./response-test-support.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) =>
  execFileAsync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd })
const shell = { id: "task-1", description: "Monitor CI", status: "running", taskType: "shell" }
const subagent = { id: "task-2", description: "Review", status: "running", taskType: "subagent" }

const withWorktreesRoot = async <A>(body: () => Promise<A>): Promise<A> => {
  const worktreesRoot = mkdtempSync(join(tmpdir(), "codevisor-agent-worktrees-"))
  tempDirs.push(worktreesRoot)
  process.env["CODEVISOR_WORKTREES_ROOT"] = worktreesRoot
  try {
    return await body()
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

  it("reads an agent as idle once its harness closes, though its tasks are still on record", async () => {
    const { server, services } = await start()
    const project = idOf(
      (
        await jsonRequest(server, "/v1/projects", {
          body: JSON.stringify({
            folderPath: mkdtempSync(join(tmpdir(), "codevisor-agent-closed-"))
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
    const { agentSessionId } = await run(services.db.getSessionSummary(agentId))

    await run(services.agents.closeAgentSession(agentSessionId!))

    expect((await jsonRequest(server, "/v1/agents?state=working")).body).toEqual({ items: [] })
    expect((await jsonRequest(server, `/v1/agents/${agentId}`)).body).toMatchObject({
      state: "idle"
    })
    expect(
      (
        await jsonRequest(server, "/v1/agents/wait", {
          body: JSON.stringify({ agentIds: [agentId], timeoutMs: 0 }),
          method: "POST"
        })
      ).body
    ).toEqual({ items: [{ agentId, state: "idle" }], timedOut: false })
  })

  it("clears an archived agent's background tasks so it doesn't read as working", async () => {
    await withWorktreesRoot(async () => {
      const { server, services, worktree, agentIn } = await gitProject()
      const agentId = await agentIn((await worktree()).name)
      await run(
        services.db.appendEvent("session.updated", agentId, { backgroundTasks: [shell, subagent] })
      )
      expect((await jsonRequest(server, `/v1/agents/${agentId}`)).body).toMatchObject({
        state: "working"
      })

      await jsonRequest(server, `/v1/agents/${agentId}/archive`, { method: "POST" })

      expect(
        (await run(services.db.getTranscriptPage(agentId, undefined, 1))).backgroundTasks
      ).toEqual([])
      expect((await jsonRequest(server, "/v1/agents")).body).toMatchObject({
        items: [{ agentId, state: "idle" }]
      })
    })
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

  it("waits for the archive to remove the checkout before answering", async () => {
    await withWorktreesRoot(async () => {
      const { server, worktree, agentIn } = await gitProject()
      const tree = await worktree()
      const agentId = await agentIn(tree.name)

      const archived = await jsonRequest(server, `/v1/agents/${agentId}/archive`, {
        method: "POST"
      })

      expect(archived.body).toEqual({ agentId, workspaceId: expect.any(String), archived: true })
      expect(existsSync(tree.path)).toBe(false)
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
