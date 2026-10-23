import { afterEach, describe, expect, it, vi } from "vitest"

import {
  bodyOf,
  call,
  caller,
  fakeServer,
  local,
  remote,
  session
} from "./codevisor-agent-test-support.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("agents.start", () => {
  it("creates a worktree, the agent on the caller's defaults, its first prompt, and the caller's subscription", async () => {
    const requests = fakeServer({ caller })

    const started = await call(local, "agents.start", {
      title: "Fix login",
      prompt: "Fix the redirect loop",
      isolation: "worktree",
      labels: { linear: "ABC-1" }
    })

    expect(started).toEqual({
      agentId: "child",
      title: "Fix login",
      projectId: "project-1",
      workspaceId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      worktreeName: "fix-login",
      delivered: "sent",
      subscribed: true
    })
    expect(requests.map(({ method, path }) => `${method} ${path}`)).toEqual([
      "GET /v1/sessions/caller",
      "POST /v1/projects/project-1/worktrees",
      "POST /v1/sessions",
      "POST /v1/sessions/child/prompt",
      "POST /v1/sessions/caller/subscriptions"
    ])
    expect(bodyOf(requests, "POST", "/v1/projects/project-1/worktrees")).toEqual({
      name: "Fix login"
    })
    expect(bodyOf(requests, "POST", "/v1/sessions")).toEqual({
      projectId: "project-1",
      harnessId: "claude-code",
      title: "Fix login",
      workspaceId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      worktreeName: "fix-login",
      parentSessionId: "caller",
      labels: { linear: "ABC-1" }
    })
    expect(bodyOf(requests, "POST", "/v1/sessions/child/prompt")).toEqual({
      text: "Fix the redirect loop",
      fromSessionId: "caller"
    })
    expect(bodyOf(requests, "POST", "/v1/sessions/caller/subscriptions")).toEqual({
      targetSessionId: "child"
    })
  })

  it("joins the caller's workspace for shared isolation and merges a model override into its picks", async () => {
    const requests = fakeServer({ caller })

    await call(local, "agents.start", {
      title: "Second opinion",
      prompt: "Review it",
      isolation: "shared",
      model: "sonnet"
    })

    expect(bodyOf(requests, "POST", "/v1/sessions")).toMatchObject({
      workspaceId: "caller-workspace",
      worktreeName: "caller-tree",
      configSelections: { model: "sonnet", reasoning: "high" }
    })
    expect(requests.some((request) => request.path.endsWith("/worktrees"))).toBe(false)
  })

  it("uses only the model for another harness and a fresh workspace for project isolation", async () => {
    const requests = fakeServer({ caller: session("caller") })

    const started = await call(local, "agents.start", {
      title: "Codex pass",
      prompt: "Go",
      isolation: "project",
      harness: "codex",
      model: "gpt",
      project: "codevisor"
    })

    expect(bodyOf(requests, "POST", "/v1/sessions")).toMatchObject({
      harnessId: "codex",
      configSelections: { model: "gpt" },
      workspaceId: expect.stringMatching(/^[0-9a-f-]{36}$/)
    })
    expect(bodyOf(requests, "POST", "/v1/sessions")).not.toHaveProperty("worktreeName")
    expect(started).not.toHaveProperty("worktreeName")
  })

  it("starts from another machine on forwarded caller defaults, needs a project, and doesn't subscribe", async () => {
    const requests = fakeServer({})
    const defaults = { harness: "claude-code", configSelections: { model: "opus" } }

    await expect(
      call(remote, "agents.start", {
        title: "t",
        prompt: "p",
        isolation: "project",
        callerDefaults: defaults
      })
    ).rejects.toThrow(
      "Pass project: an id or name. Projects on this machine: Codevisor (project-1)"
    )
    await expect(
      call(remote, "agents.start", {
        title: "t",
        prompt: "p",
        isolation: "project",
        project: "nope"
      })
    ).rejects.toThrow('No project matches "nope"')
    await expect(
      call(remote, "agents.start", {
        title: "t",
        prompt: "p",
        isolation: "project",
        project: "project-1"
      })
    ).rejects.toThrow("Pass harness")
    await expect(
      call(remote, "agents.start", {
        title: "t",
        prompt: "p",
        isolation: "shared",
        project: "project-1",
        callerDefaults: defaults
      })
    ).rejects.toThrow('isolation: "shared" joins your own workspace')

    const started = await call(remote, "agents.start", {
      title: "Remote",
      prompt: "p",
      isolation: "project",
      project: "Codevisor",
      callerDefaults: defaults
    })

    expect(started).toMatchObject({ agentId: "child", subscribed: false })
    expect(bodyOf(requests, "POST", "/v1/sessions")).toMatchObject({
      harnessId: "claude-code",
      configSelections: { model: "opus" }
    })
    expect(bodyOf(requests, "POST", "/v1/sessions")).not.toHaveProperty("parentSessionId")
    expect(requests.some((request) => request.path.endsWith("/subscriptions"))).toBe(false)
  })

  it("reports only what the server returned, and joins a shared project folder without a worktree", async () => {
    const requests = fakeServer(
      { caller: session("caller", { workspaceId: "caller-workspace" }) },
      [],
      { bare: true }
    )

    const started = await call(local, "agents.start", {
      title: "t",
      prompt: "p",
      isolation: "shared"
    })

    expect(started).toEqual({
      agentId: "child",
      title: "Agent child",
      projectId: "project-1",
      subscribed: true
    })
    expect(bodyOf(requests, "POST", "/v1/sessions")).toMatchObject({
      workspaceId: "caller-workspace"
    })
    expect(bodyOf(requests, "POST", "/v1/sessions")).not.toHaveProperty("worktreeName")
  })

  it("says when a machine has no projects at all", async () => {
    fakeServer({}, [], { projects: [] })

    await expect(
      call(remote, "agents.start", { title: "t", prompt: "p", isolation: "project" })
    ).rejects.toThrow("Projects on this machine: none")
  })

  it("reports a failed Codevisor request with the tool name", async () => {
    fakeServer({})

    await expect(
      call(local, "agents.start", { title: "t", prompt: "p", isolation: "project" })
    ).rejects.toThrow("agents.start failed (404): Session not found")
  })
})
