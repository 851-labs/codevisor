import { execFile } from "node:child_process"
import { mkdirSync, mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import type { CreateSessionOptions } from "@codevisor/agent-runtime"
import { decode, SessionSummary, Worktree } from "@codevisor/api"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { jsonRequest, run, tempDirs, waitFor } from "../test-support.js"
import { idOf } from "./response-test-support.js"
import { setUpWorkspace } from "./session-test-support.js"

const git = (args: ReadonlyArray<string>, cwd: string) =>
  promisify(execFile)("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd })

afterEach(() => {
  delete process.env["CODEVISOR_WORKTREES_ROOT"]
})

interface ForkSetup {
  readonly canFork?: boolean
  readonly failFork?: boolean
}

const forkingAgents = async ({ canFork = true, failFork = false }: ForkSetup = {}) => {
  const running = await setUpWorkspace()
  const { agents } = running
  const forks: Array<CreateSessionOptions | undefined> = []
  const create = agents.createAgentSession.bind(agents)
  vi.spyOn(agents, "createAgentSession").mockImplementation(
    (harnessId, cwd, sink, account, gateway, options) => {
      const created = create(harnessId, cwd, sink, account, gateway, options)
      if (options?.forkFrom === undefined) return created
      forks.push(options)
      if (failFork) return Effect.die(new Error("fork failed"))
      return Effect.as(created, `${options.forkFrom}-fork`)
    }
  )
  const load = agents.loadAgentSession.bind(agents)
  vi.spyOn(agents, "loadAgentSession").mockImplementation((...args) =>
    Effect.map(load(...args), (metadata) => ({
      ...metadata,
      skills: { invocationPrefix: "/", skills: [], commands: canFork ? ["fork"] : [] }
    }))
  )
  return { ...running, forks }
}

type Running = Awaited<ReturnType<typeof forkingAgents>>

const chatIn = async (running: Running, fields: Record<string, unknown> = {}) => {
  const { server, services, workspace } = running
  const created = await jsonRequest(server, "/v1/sessions", {
    body: JSON.stringify({
      projectId: workspace.id,
      harnessId: "codex",
      title: "First chat",
      ...fields
    }),
    method: "POST"
  })
  const sessionId = idOf(created.body)
  const reply = async (text: string) => {
    await jsonRequest(server, `/v1/sessions/${sessionId}/prompt`, {
      body: JSON.stringify({ text }),
      method: "POST"
    })
  }
  const settled = () =>
    waitFor(async () => {
      const page = await run(services.db.getTranscriptPage(sessionId, undefined, 8))
      return page.items.some((item) => item.text === "Echo: hello")
    })
  const fork = () => jsonRequest(server, `/v1/sessions/${sessionId}/fork`, { method: "POST" })
  return { sessionId, reply, settled, fork }
}

const repoWorktree = async (running: Running): Promise<{ projectId: string; name: string }> => {
  process.env["CODEVISOR_WORKTREES_ROOT"] = mkdtempSync(join(tmpdir(), "codevisor-fork-trees-"))
  tempDirs.push(process.env["CODEVISOR_WORKTREES_ROOT"])
  const repo = join(mkdtempSync(join(tmpdir(), "codevisor-fork-repo-")), "repo")
  tempDirs.push(repo)
  mkdirSync(repo)
  await git(["init"], repo)
  await git(["commit", "--allow-empty", "-m", "init"], repo)
  const project = await jsonRequest(running.server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repo }),
    method: "POST"
  })
  const projectId = idOf(project.body)
  const tree = await jsonRequest(running.server, `/v1/projects/${projectId}/worktrees`, {
    body: JSON.stringify({ name: "forked work" }),
    method: "POST"
  })
  return { projectId, name: decode(Worktree)(tree.body).name }
}

const sessionCount = async (running: Running): Promise<number> =>
  (await run(running.services.db.listSessions)).length

describe("POST /v1/sessions/:id/fork", () => {
  it("forks the chat into a new workspace nested under it, with the history copied", async () => {
    const running = await forkingAgents()
    const chat = await chatIn(running)
    await chat.reply("hello")
    await chat.settled()
    const account = await run(
      running.services.db.saveHarnessAccount({
        authState: "authenticated",
        canLogin: true,
        canLogout: true,
        harnessId: "codex",
        label: "Work",
        profileKind: "default"
      })
    )
    await run(running.services.db.bindSessionHarnessAccount(chat.sessionId, account.id))

    const response = await chat.fork()

    expect(response.status).toBe(201)
    const forked = decode(SessionSummary)(response.body)
    const original = await run(running.services.db.getSessionSummary(chat.sessionId))
    expect(forked).toMatchObject({
      parentSessionId: chat.sessionId,
      projectId: original.projectId,
      harnessAccountId: account.id,
      title: "First chat (fork)",
      agentSessionId: `${original.agentSessionId}-fork`
    })
    expect(forked.workspaceId).not.toBe(original.workspaceId)
    expect(running.forks.map((options) => options?.forkFrom)).toEqual([original.agentSessionId])
    const items = (await run(running.services.db.getTranscriptPage(forked.id, undefined, 8))).items
    expect(items.map((item) => [item.role, item.text, item.origin])).toEqual([
      ["user", "hello", undefined],
      ["assistant", "Echo: hello", undefined],
      ["user", "Forked from First chat", "fork"]
    ])
  })

  it("nests a fork of a fork under the first fork, without stacking the title", async () => {
    const running = await forkingAgents()
    const chat = await chatIn(running)
    await chat.reply("hello")
    await chat.settled()
    const first = decode(SessionSummary)((await chat.fork()).body)

    const response = await jsonRequest(running.server, `/v1/sessions/${first.id}/fork`, {
      method: "POST"
    })

    expect(decode(SessionSummary)(response.body)).toMatchObject({
      parentSessionId: first.id,
      title: "First chat (fork)"
    })
  })

  it("keeps the fork's title when the agent reports the source's name for it", async () => {
    const running = await forkingAgents()
    const chat = await chatIn(running)
    await chat.reply("hello")
    await chat.settled()
    const forked = decode(SessionSummary)((await chat.fork()).body)

    await run(running.services.db.updateSessionTitleFromHarness(forked.id, "First chat"))

    expect((await run(running.services.db.getSessionSummary(forked.id))).title).toBe(
      "First chat (fork)"
    )
  })

  it("keeps a fork in the same worktree as its source", async () => {
    const running = await forkingAgents()
    const tree = await repoWorktree(running)
    const chat = await chatIn(running, { projectId: tree.projectId, worktreeName: tree.name })
    await chat.reply("hello")
    await chat.settled()

    const forked = decode(SessionSummary)((await chat.fork()).body)

    expect(forked).toMatchObject({ projectId: tree.projectId, worktreeName: tree.name })
  })

  it("refuses an agent that can't fork, without leaving a chat behind", async () => {
    const running = await forkingAgents({ canFork: false })
    const chat = await chatIn(running)
    await chat.reply("hello")
    await chat.settled()
    const before = await sessionCount(running)

    const response = await chat.fork()

    expect([response.status, response.body]).toEqual([
      409,
      { error: "This agent can't fork chats" }
    ])
    expect(await sessionCount(running)).toBe(before)
  })

  it("refuses while the agent is working, or before the chat has an agent", async () => {
    const running = await forkingAgents()
    const working = await chatIn(running)
    await working.reply("slow prompt")
    const unstarted = await chatIn(running, { deferAgentSession: true })

    const responses = [await working.fork(), await unstarted.fork()]
    running.agents.releasePrompt()

    expect(responses.map((response) => [response.status, response.body])).toEqual([
      [409, { error: "Wait for the agent to finish before forking this chat" }],
      [409, { error: "Send a message before forking this chat" }]
    ])
  })

  it("removes the new chat when the agent fails to fork", async () => {
    const running = await forkingAgents({ failFork: true })
    const chat = await chatIn(running)
    await chat.reply("hello")
    await chat.settled()
    const before = await sessionCount(running)

    const response = await chat.fork()

    expect(response.status).toBe(500)
    expect(await sessionCount(running)).toBe(before)
  })
})
