import { afterEach, describe, expect, it, vi } from "vitest"

import {
  bodyOf,
  call,
  fakeServer,
  itemsOf,
  local,
  question,
  remote,
  transcriptItem
} from "./codevisor-agent-test-support.js"
import { expectRecord, expectString } from "./unknown-values.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

const summary = (agentId: string) => ({
  agentId,
  title: `Agent ${agentId}`,
  state: "idle",
  projectId: "project-1",
  harness: "claude-code"
})

describe("agents.list", () => {
  it("forwards its filters", async () => {
    const requests = fakeServer([summary("a")])

    const listed = await call(local, "agents.list", {
      state: "working",
      project: "Codevisor",
      createdByAgentId: "caller",
      label: "role=worker"
    })

    expect(listed).toEqual({ items: [summary("a")] })
    expect(requests.find((request) => request.path === "/v1/agents")?.query).toEqual({
      state: "working",
      project: "Codevisor",
      createdByAgentId: "caller",
      label: "role=worker"
    })
  })

  it("pages fifty at a time with next", async () => {
    fakeServer(Array.from({ length: 51 }, (_, index) => summary(`s${index}`)))

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

describe("agents.detach", () => {
  it("asks the agent's machine to let it stand alone", async () => {
    const requests = fakeServer()

    const detached = await call(local, "agents.detach", { agentId: "worker" })

    expect(detached).toEqual({ agentId: "worker", workspaceId: "own", detached: true })
    expect(requests.map(({ method, path }) => [method, path])).toEqual([
      ["POST", "/v1/agents/worker/detach"]
    ])
  })
})

describe("agents.archive", () => {
  it("names the local caller so the server can tell a shared helper from an agent of its own", async () => {
    const requests = fakeServer()

    const archived = await call(local, "agents.archive", { agentId: "worker" })
    const fromRemote = await call(remote, "agents.archive", { agentId: "far-worker" })

    expect(archived).toEqual({ agentId: "worker", archived: true })
    expect(fromRemote).toEqual({ agentId: "far-worker", archived: true })
    expect(requests.map(({ method, path, body }) => [method, path, body])).toEqual([
      ["POST", "/v1/agents/worker/archive", { callerAgentId: "caller" }],
      ["POST", "/v1/agents/far-worker/archive", {}]
    ])
  })

  it("passes on failures with the route that broke", async () => {
    fakeServer([], { failing: ["POST /v1/agents/worker/archive"] })

    await expect(call(local, "agents.archive", { agentId: "worker" })).rejects.toThrow(
      "POST /v1/agents/worker/archive broke"
    )
  })
})

describe("agent subscriptions", () => {
  it("subscribes, lists, and unsubscribes as the caller with agent-named fields", async () => {
    const requests = fakeServer()

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
      "agents.subscribe only works for agents on your own machine"
    )
  })
})

describe("agents.wait", () => {
  it("sends agent states and ids, clamped to the execute budget", async () => {
    const requests = fakeServer()
    const tight = { sessionId: "caller", deadline: performance.now() + 30_000 }

    const waited = await call(tight, "agents.wait", {
      agentIds: ["a", "b"],
      until: ["working", "idle"],
      timeoutMs: 120_000
    })
    const roomy = await call(local, "agents.wait", { agentIds: ["a"] })

    const sent = expectRecord(bodyOf(requests, "POST", "/v1/agents/wait"), "wait body")
    expect(sent).toEqual({
      agentIds: ["a", "b"],
      until: ["working", "idle"],
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
    expect(requests.at(-1)?.body).toEqual({ agentIds: ["a"] })
  })
})

describe("agents.debug.transcript", () => {
  it("pages the raw transcript with agent-named ids and next", async () => {
    const requests = fakeServer()

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
