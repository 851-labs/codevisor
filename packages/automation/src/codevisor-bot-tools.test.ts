import { afterEach, describe, expect, it, vi } from "vitest"

import { makeCodevisorProvider } from "./codevisor-provider.js"

interface SentRequest {
  readonly method: string
  readonly path: string
  readonly query?: string
  readonly body?: unknown
}

const context = { sessionId: "caller", projectId: "project" }

const bot = { id: "b1", projectId: "home", sessionId: "s1", projects: [{ projectId: "p1" }] }

const fakeServer = (reply: unknown = bot): SentRequest[] => {
  const sent: SentRequest[] = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (url: URL, init: RequestInit) => {
      const body = typeof init.body === "string" ? JSON.parse(init.body) : undefined
      sent.push({
        method: init.method!,
        path: url.pathname,
        ...(url.search === "" ? {} : { query: url.search }),
        ...(body === undefined ? {} : { body })
      })
      return new Response(JSON.stringify(reply), {
        headers: { "content-type": "application/json" }
      })
    })
  )
  return sent
}

const provider = () =>
  makeCodevisorProvider(
    () => "http://localhost:5000",
    async () => "token"
  )

const resultOf = async (tool: string, args: Record<string, unknown>): Promise<unknown> => {
  const result = await provider().invoke(context, tool, args)
  const first = result.content[0]
  return first?.type === "text" ? JSON.parse(first.text) : undefined
}

describe("bot tools", () => {
  afterEach(() => vi.unstubAllGlobals())

  it("create a bot like the app's New Bot sheet unless told otherwise", async () => {
    const sent = fakeServer()
    const create = provider().tools.find((tool) => tool.name === "bots.create")!

    const created = await resultOf("bots.create", {
      name: "Triage",
      harnessId: "codex",
      projectIds: ["p1"]
    })
    await resultOf("bots.create", {
      name: "Notes",
      harnessId: "codex",
      projectIds: ["p1"],
      mascot: { color: "sky", hat: "beanie", hatColor: "red", eyewear: "none" }
    })

    expect(create.inputSchema.required).toEqual(["name", "harnessId", "projectIds"])
    expect(JSON.stringify(create.inputSchema.properties?.["mascot"])).toContain("propeller")
    expect(sent.map((request) => request.body)).toEqual([
      {
        name: "Triage",
        harnessId: "codex",
        projectIds: ["p1"],
        symbolName: "sparkles"
      },
      {
        name: "Notes",
        harnessId: "codex",
        projectIds: ["p1"],
        symbolName: "sparkles",
        mascot: { color: "sky", hat: "beanie", hatColor: "red", eyewear: "none" }
      }
    ])
    expect(created).toEqual({
      botId: "b1",
      projectId: "home",
      agentId: "s1",
      projects: [{ projectId: "p1" }]
    })
  })

  it("address each bot by botId and delete one only with confirm", async () => {
    const sent = fakeServer()

    await resultOf("bots.get", { botId: "b1" })
    await resultOf("bots.update", { botId: "b1", isArchived: true })
    await resultOf("bots.fork", { botId: "b1", harnessId: "claude-code", moveAgents: false })
    await resultOf("bots.projects_add", { botId: "b1", projectId: "p2" })
    await resultOf("bots.projects_remove", { botId: "b1", projectId: "p1" })
    await expect(provider().invoke(context, "bots.delete", { botId: "b1" })).rejects.toThrow(
      "bots.delete requires confirm: true"
    )
    await resultOf("bots.delete", { botId: "b1", confirm: true })

    expect(sent).toEqual([
      { method: "GET", path: "/v1/bots/b1" },
      { method: "PATCH", path: "/v1/bots/b1", body: { isArchived: true } },
      {
        method: "POST",
        path: "/v1/bots/b1/fork",
        body: { harnessId: "claude-code", moveAgents: false }
      },
      { method: "POST", path: "/v1/bots/b1/projects", body: { projectId: "p2" } },
      { method: "DELETE", path: "/v1/bots/b1/projects/p1" },
      { method: "DELETE", path: "/v1/bots/b1" }
    ])
  })

  it("message a bot and read that thread as the calling bot or agent", async () => {
    const message = { from: "Release", mine: false, text: "Yes.", sentAt: "2026-11-12T00:00:00Z" }
    const sent = fakeServer({ threadId: "t1", messages: [message], next: 2 })

    await resultOf("bots.message", { botId: "b1", text: "Is the build green?" })
    const read = await resultOf("bots.messages", { botId: "b1", limit: 5 })

    expect(sent).toEqual([
      {
        method: "POST",
        path: "/v1/bots/b1/messages",
        body: { text: "Is the build green?", sentByAgentId: "caller" }
      },
      { method: "GET", path: "/v1/bots/b1/messages", query: "?sentByAgentId=caller&limit=5" }
    ])
    expect(read).toEqual({ threadId: "t1", items: [message], next: 2 })
  })
})
