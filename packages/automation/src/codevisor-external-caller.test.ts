import { externalClientSessionKey, remoteSessionKey } from "@codevisor/api"
import { afterEach, describe, expect, it, vi } from "vitest"

import { makeCodevisorProvider } from "./codevisor-provider.js"
import { expectString } from "./unknown-values.js"

const jsonResponse = (body: unknown): Response =>
  new Response(JSON.stringify(body), { headers: { "content-type": "application/json" } })

const requestJson = (init: RequestInit): unknown =>
  JSON.parse(expectString(init.body, "request body"))

const stubFetch = (responder: (url: URL, init: RequestInit) => Response): void => {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: string | URL, init?: RequestInit) =>
      responder(new URL(input.toString()), init ?? {})
    )
  )
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("Codevisor tools called by an MCP client outside Codevisor", () => {
  it("acts for no chat when an MCP client outside Codevisor calls, here or from another machine", async () => {
    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ agentId: "child", title: "Fix", projectId: "p", subscribed: false })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )
    const external = { sessionId: externalClientSessionKey("grok"), projectId: "widget" }
    const relayed = { sessionId: remoteSessionKey("mbp", externalClientSessionKey("grok")) }
    const start = { prompt: "Go", title: "Fix", checkout: "worktree" }

    await provider.invoke(external, "agents.start", start)
    await provider.invoke(external, "agents.start", { ...start, checkout: "none" })
    await provider.invoke(relayed, "agents.start", start)
    await provider.invoke(external, "agents.message", { agentId: "child", text: "more" })
    await provider.invoke(external, "shell.exec", { command: "true" })

    expect(requests.map((request) => requestJson(request.init))).toEqual([
      { ...start, project: "widget" },
      { ...start, checkout: "none" },
      start,
      { text: "more" },
      { command: "true" }
    ])
    await expect(
      provider.invoke(external, "agents.subscribe", { agentId: "child" })
    ).rejects.toThrow("Follow agents with agents.wait and agents.status instead")
  })
})
