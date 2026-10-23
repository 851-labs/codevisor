import { afterEach, describe, expect, it, vi } from "vitest"

import {
  bodyOf,
  call,
  caller,
  fakeServer,
  itemsOf,
  local,
  question,
  remote,
  session,
  transcriptItem
} from "./codevisor-agent-test-support.js"
import { expectRecord, expectString } from "./unknown-values.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("agents.list", () => {
  const listed = [
    session("a", {
      sidebarState: "inProgress",
      parentSessionId: "caller",
      labels: { role: "worker" }
    }),
    session("b", {
      sidebarState: "waitingForUser",
      workspaceId: "w-b",
      worktreeName: "b",
      updatedAt: "now"
    }),
    session("c", { sidebarState: "idle", actionRequired: true, projectId: "other" }),
    session("d", { sidebarState: "errored" }),
    session("e", { sidebarState: "unread" })
  ]

  it("returns slim summaries filtered by state and project, forwarding parent and label filters", async () => {
    const requests = fakeServer({}, listed)

    const working = await call(local, "agents.list", {
      state: "working",
      parentAgentId: "caller",
      label: "role=worker"
    })
    const waiting = await call(local, "agents.list", {
      state: "waitingForUser",
      project: "Codevisor"
    })
    const all = await call(local, "agents.list", {})

    expect(working).toEqual({
      items: [
        {
          agentId: "a",
          title: "Agent a",
          state: "working",
          projectId: "project-1",
          harness: "claude-code",
          labels: { role: "worker" },
          parentAgentId: "caller"
        }
      ]
    })
    expect(waiting).toEqual({
      items: [
        {
          agentId: "b",
          title: "Agent b",
          state: "waitingForUser",
          projectId: "project-1",
          harness: "claude-code",
          workspaceId: "w-b",
          worktreeName: "b",
          updatedAt: "now"
        }
      ]
    })
    expect(all).toMatchObject({
      items: [
        { agentId: "a", state: "working" },
        { agentId: "b", state: "waitingForUser" },
        { agentId: "c", state: "waitingForUser" },
        { agentId: "d", state: "errored" },
        { agentId: "e", state: "idle" }
      ]
    })
    expect(requests.find((request) => request.path === "/v1/sessions")?.query).toEqual({
      parentSessionId: "caller",
      label: "role=worker"
    })
  })

  it("pages fifty at a time with next", async () => {
    fakeServer(
      {},
      Array.from({ length: 51 }, (_, index) => session(`s${index}`))
    )

    const first = await call(local, "agents.list", {})
    const second = await call(local, "agents.list", { next: "50" })

    expect(first).toMatchObject({ next: "50" })
    expect(itemsOf(first)).toHaveLength(50)
    expect(second).toEqual({ items: [expect.objectContaining({ agentId: "s50" })] })
    await expect(call(local, "agents.list", { next: "-1" })).rejects.toThrow(
      "next must come from an earlier agents.list"
    )
  })
})

describe("agents.archive", () => {
  it("archives a worker's workspace but refuses one shared with the caller or missing", async () => {
    const requests = fakeServer({
      caller,
      worker: session("worker", { workspaceId: "worker-workspace" }),
      helper: session("helper", { workspaceId: "CALLER-WORKSPACE" }),
      loose: session("loose")
    })

    const archived = await call(local, "agents.archive", { agentId: "worker" })
    const fromRemote = await call(remote, "agents.archive", { agentId: "helper" })

    expect(archived).toEqual({ agentId: "worker", workspaceId: "worker-workspace", archived: true })
    expect(fromRemote).toMatchObject({ archived: true })
    expect(bodyOf(requests, "PATCH", "/v1/workspaces/worker-workspace")).toEqual({
      isArchived: true
    })
    await expect(call(local, "agents.archive", { agentId: "helper" })).rejects.toThrow(
      "shares your workspace"
    )
    await expect(call(local, "agents.archive", { agentId: "loose" })).rejects.toThrow(
      "has no workspace to archive"
    )
  })
})

describe("agent subscriptions", () => {
  it("subscribes, lists, and unsubscribes as the caller with agent-named fields", async () => {
    const requests = fakeServer({})

    const created = await call(local, "agents.subscribe", {
      agentId: "other",
      events: ["turn_ended"],
      once: true
    })
    const minimal = await call(local, "agents.subscribe", { agentId: "other" })
    const held = await call(local, "agents.subscriptions", {})
    const removed = await call(local, "agents.unsubscribe", { subscriptionId: "sub-1" })

    const item = {
      subscriptionId: "sub-1",
      agentId: "other",
      events: ["turn_ended"],
      once: true,
      createdAt: "2026-10-23T00:00:00.000Z"
    }
    expect(created).toEqual(item)
    expect(minimal).toEqual(item)
    expect(held).toEqual({ items: [item] })
    expect(removed).toEqual({ subscriptionId: "sub-1", removed: true })
    expect(requests.map(({ method, path, body }) => [method, path, body])).toEqual([
      [
        "POST",
        "/v1/sessions/caller/subscriptions",
        { targetSessionId: "other", events: ["turn_ended"], once: true }
      ],
      ["POST", "/v1/sessions/caller/subscriptions", { targetSessionId: "other" }],
      ["GET", "/v1/sessions/caller/subscriptions", undefined],
      ["DELETE", "/v1/sessions/caller/subscriptions/sub-1", undefined]
    ])
    await expect(call(remote, "agents.subscribe", { agentId: "other" })).rejects.toThrow(
      "agents.subscribe works on your own machine only"
    )
  })
})

describe("agents.wait", () => {
  it("maps agent states to sidebar states and back, clamped to the execute budget", async () => {
    const requests = fakeServer({})
    const tight = { sessionId: "caller", deadline: performance.now() + 30_000 }

    const waited = await call(tight, "agents.wait", {
      agentIds: ["a", "b"],
      until: ["working", "waitingForUser", "idle", "errored"],
      timeoutMs: 120_000
    })
    const roomy = await call(local, "agents.wait", { agentIds: ["a"] })

    const sent = expectRecord(bodyOf(requests, "POST", "/v1/sessions/wait"), "wait body")
    expect(sent).toEqual({
      ids: ["a", "b"],
      until: ["inProgress", "waitingForUser", "idle", "errored"],
      timeoutMs: expect.any(Number)
    })
    expect(sent.timeoutMs).toBeLessThan(30_000)
    expect(waited).toEqual({
      items: [
        { agentId: "a", state: "working" },
        { agentId: "b", state: "waitingForUser", pendingQuestion: question }
      ],
      timedOut: false,
      clampedToMs: sent.timeoutMs
    })
    expect(roomy).not.toHaveProperty("clampedToMs")
    expect(requests.at(-1)?.body).toEqual({ ids: ["a"] })
  })
})

describe("agents.debug.transcript", () => {
  it("pages the raw transcript with agent-named ids and next", async () => {
    const requests = fakeServer({})

    const page = await call(local, "agents.debug.transcript", {
      agentId: "child",
      next: "cursor",
      limit: 5
    })
    const newest = await call(local, "agents.debug.transcript", { agentId: "child" })
    const oldest = await call(local, "agents.debug.transcript", { agentId: "child", next: "older" })

    expect(page).toEqual({
      items: [{ itemId: "item-1", ...transcriptItem, sessionId: undefined, agentId: "child" }],
      next: "older"
    })
    expect(newest).toEqual(page)
    expect(oldest).not.toHaveProperty("next")
    expect(requests.map((request) => request.query)).toEqual([
      { before: "cursor", limit: "5" },
      {},
      { before: "older" }
    ])
    expect(expectString(requests[0]!.path, "path")).toBe("/v1/sessions/child/transcript")
  })
})
