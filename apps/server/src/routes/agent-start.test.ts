import { execFile } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { decode, StartedAgent } from "@codevisor/api"
import { DatabaseError } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import { jsonRequest, run, start, tempDirs, waitFor } from "../test-support.js"
import { AGENT_START_CLEANUP_MS, rolledBack } from "./agent-start.js"
import { idOf } from "./response-test-support.js"

const execFileAsync = promisify(execFile)
const git = (args: ReadonlyArray<string>, cwd: string) =>
  execFileAsync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd })

afterEach(() => {
  vi.restoreAllMocks()
  delete process.env["CODEVISOR_WORKTREES_ROOT"]
})

const startable = async () => {
  process.env["CODEVISOR_WORKTREES_ROOT"] = mkdtempSync(join(tmpdir(), "codevisor-start-trees-"))
  tempDirs.push(process.env["CODEVISOR_WORKTREES_ROOT"])
  const running = await start()
  const repo = join(mkdtempSync(join(tmpdir(), "codevisor-start-repo-")), "repo")
  tempDirs.push(repo)
  mkdirSync(repo)
  await git(["init"], repo)
  writeFileSync(join(repo, "README.md"), "hi\n")
  await git(["add", "README.md"], repo)
  await git(["commit", "-m", "init"], repo)
  await jsonRequest(running.server, "/v1/projects", {
    body: JSON.stringify({ folderPath: repo, id: "start-project", name: "Start" }),
    method: "POST"
  })
  const caller = idOf(
    (
      await jsonRequest(running.server, "/v1/sessions", {
        body: JSON.stringify({ projectId: "start-project", harnessId: "codex" }),
        method: "POST"
      })
    ).body
  )
  const startAgent = (fields: Record<string, unknown>) =>
    jsonRequest(running.server, "/v1/agents", {
      body: JSON.stringify({
        prompt: "Fix it",
        title: "Fix login",
        isolation: "worktree",
        callerAgentId: caller,
        ...fields
      }),
      method: "POST"
    })
  const state = async () => ({
    sessions: (await run(running.services.db.listSessions)).map((session) => session.id),
    worktrees: await run(running.services.db.listWorktrees("start-project")),
    branches: (await git(["branch", "--list", "codevisor/*"], repo)).stdout.trim()
  })
  return { ...running, repo, caller, startAgent, state }
}

describe("POST /v1/agents", () => {
  it("creates the worktree and chat, subscribes the caller, then sends the first prompt", async () => {
    const { agents, services, caller, startAgent } = await startable()

    const response = await startAgent({ labels: { role: "worker" } })

    expect(response.status).toBe(201)
    const started = decode(StartedAgent)(response.body)
    expect(started).toMatchObject({ projectId: "start-project", subscribed: true })
    expect(started.worktreeName).toEqual(expect.any(String))
    const subscriptions = await run(services.db.listSessionSubscriptions(caller))
    expect(subscriptions).toEqual([expect.objectContaining({ targetSessionId: started.agentId })])
    const child = await run(services.db.getSessionSummary(started.agentId))
    expect(child).toMatchObject({ parentSessionId: caller, labels: { role: "worker" } })
    await waitFor(() => agents.prompts.some(([, text]) => text === "Fix it"))
  })

  it("removes the worktree it allocated when the chat can't be created", async () => {
    const { services, startAgent, state } = await startable()
    const before = await state()
    vi.spyOn(services.db, "createWorkspaceWithSession").mockReturnValueOnce(
      Effect.fail(
        new DatabaseError({ operation: "createWorkspaceWithSession", message: "database locked" })
      )
    )

    const response = await startAgent({})

    expect(response.status).toBeGreaterThanOrEqual(400)
    expect(JSON.stringify(response.body)).toContain("database locked")
    expect(await state()).toEqual(before)
  })

  it("removes the chat and worktree it created when the first prompt can't be queued", async () => {
    const { services, startAgent, state } = await startable()
    const before = await state()
    vi.spyOn(services.db, "createPromptQueueItem").mockReturnValueOnce(
      Effect.fail(new DatabaseError({ operation: "createPromptQueueItem", message: "disk full" }))
    )

    const response = await startAgent({})

    expect(response.status).toBeGreaterThanOrEqual(400)
    expect(JSON.stringify(response.body)).toContain("disk full")
    expect(await state()).toEqual(before)
  })

  it("keeps the worktree record when its checkout no longer matches what the start created", async () => {
    const { services, startAgent, state } = await startable()
    vi.spyOn(services.db, "createPromptQueueItem").mockImplementationOnce((agentId) =>
      Effect.flatMap(
        Effect.promise(async () => {
          const child = await run(services.db.getSessionSummary(agentId))
          await git(["checkout", "-b", "someone-else"], child.cwd!)
        }),
        () =>
          Effect.fail(
            new DatabaseError({ operation: "createPromptQueueItem", message: "disk full" })
          )
      )
    )

    const response = await startAgent({})

    expect(JSON.stringify(response.body)).toContain("its checkout no longer matches")
    const { worktrees } = await state()
    expect(worktrees).toHaveLength(1)
    expect(existsSync(worktrees[0]!.path)).toBe(true)
  })

  it("starts from another machine on forwarded defaults, a named project, and a model", async () => {
    const { services, startAgent } = await startable()

    const response = await startAgent({
      callerAgentId: undefined,
      callerDefaults: { harness: "codex", configSelections: { reasoning: "high" } },
      project: "start",
      model: "gpt-6",
      isolation: "project"
    })

    const started = decode(StartedAgent)(response.body)
    expect(started.subscribed).toBe(false)
    expect(await run(services.db.getSessionSummary(started.agentId))).toMatchObject({
      configSelections: { reasoning: "high", model: "gpt-6" }
    })
    const inherited = decode(StartedAgent)(
      (
        await startAgent({
          callerAgentId: undefined,
          callerDefaults: { harness: "codex", configSelections: { reasoning: "low" } },
          project: "start-project",
          isolation: "project"
        })
      ).body
    )
    expect(await run(services.db.getSessionSummary(inherited.agentId))).toMatchObject({
      configSelections: { reasoning: "low" }
    })
    expect(
      (await startAgent({ callerAgentId: undefined, project: "start", isolation: "project" })).body
    ).toMatchObject({ error: expect.stringContaining("Pass harness") })
    expect(
      (await startAgent({ callerAgentId: undefined, harness: "codex", isolation: "project" })).body
    ).toMatchObject({ error: expect.stringContaining("Pass project") })
  })

  it("starts a same-harness agent on the effort its caller is running", async () => {
    const { services, caller, startAgent } = await startable()
    await run(
      services.db.saveSessionRuntimeState(caller, {
        configOptions: [
          {
            category: "thought_level",
            currentValue: "medium",
            id: "reasoning",
            name: "Reasoning",
            options: [
              { name: "Medium", value: "medium" },
              { name: "High", value: "high" }
            ]
          }
        ]
      })
    )

    const withModel = decode(StartedAgent)(
      (await startAgent({ model: "gpt-6", isolation: "project" })).body
    )
    const withoutModel = decode(StartedAgent)((await startAgent({ isolation: "project" })).body)

    expect(await run(services.db.getSessionSummary(withModel.agentId))).toMatchObject({
      configSelections: { reasoning: "medium", model: "gpt-6" }
    })
    expect(await run(services.db.getSessionSummary(withoutModel.agentId))).toMatchObject({
      configSelections: { reasoning: "medium" }
    })
  })

  it("uses only the model when the new agent runs another harness", async () => {
    const { services, startAgent } = await startable()

    const started = decode(StartedAgent)(
      (await startAgent({ harness: "claude-code", model: "opus", isolation: "project" })).body
    )

    expect(await run(services.db.getSessionSummary(started.agentId))).toMatchObject({
      harnessId: "claude-code",
      configSelections: { model: "opus" }
    })
  })

  it("shares a worktree caller's checkout", async () => {
    const { startAgent } = await startable()
    const worker = decode(StartedAgent)((await startAgent({})).body)

    const helper = decode(StartedAgent)(
      (await startAgent({ callerAgentId: worker.agentId, isolation: "shared" })).body
    )

    expect(helper).toMatchObject({
      workspaceId: worker.workspaceId,
      worktreeName: worker.worktreeName
    })
  })

  it("joins the caller's workspace and checkout for shared isolation", async () => {
    const { server, startAgent } = await startable()
    const joined = idOf(
      (
        await jsonRequest(server, "/v1/sessions", {
          body: JSON.stringify({
            projectId: "start-project",
            harnessId: "codex",
            workspaceId: "11111111-1111-4111-8111-111111111111"
          }),
          method: "POST"
        })
      ).body
    )

    const response = await startAgent({ callerAgentId: joined, isolation: "shared" })

    expect(decode(StartedAgent)(response.body)).toMatchObject({
      workspaceId: "11111111-1111-4111-8111-111111111111",
      subscribed: true
    })
  })

  it("leaves a shared start's workspace alone when it fails", async () => {
    const { startAgent } = await startable()

    expect((await startAgent({ isolation: "shared" })).status).toBe(422)
    expect((await startAgent({ project: "missing" })).status).toBe(422)
    expect(
      (await startAgent({ callerAgentId: "00000000-0000-4000-8000-000000000000" })).status
    ).toBe(422)
  })
})

describe("start rollback", () => {
  it("runs every cleanup step, bounds a hanging one, and names what failed", async () => {
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    try {
      const ran: Array<string> = []
      const outcome = rolledBack(new Error("prompt failed"), [
        async () => {
          ran.push("worktree")
        },
        () => new Promise(() => undefined),
        async () => {
          ran.push("chat")
          throw new Error("chat stuck")
        }
      ])

      await vi.advanceTimersByTimeAsync(AGENT_START_CLEANUP_MS)

      const error = await outcome
      expect(ran).toEqual(["chat", "worktree"])
      expect(String(error)).toContain("prompt failed")
      expect(String(error)).toContain("chat stuck; cleanup timed out")
    } finally {
      vi.useRealTimers()
    }
  })

  it("names a cleanup failure that isn't an Error", async () => {
    const error = await rolledBack(new Error("prompt failed"), [() => Promise.reject("reset")])

    expect(String(error)).toContain("also failed: reset")
  })

  it("returns the original error when cleanup succeeds", async () => {
    const cause = new Error("prompt failed")

    expect(await rolledBack(cause, [async () => undefined])).toBe(cause)
  })
})
