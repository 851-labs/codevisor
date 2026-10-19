import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it, vi } from "vitest"

import type { AutomationProviderContext } from "./automation-provider.js"
import { CodeExecutionToolError } from "./code-executor.js"
import { makeCodevisorProvider } from "./codevisor-provider.js"
import { expectRecord, expectString } from "./unknown-values.js"

const callingContext: AutomationProviderContext = {
  sessionId: "calling session/id",
  projectId: "calling project/id"
}

const textContent = (result: CallToolResult): string => {
  const content = result.content[0]
  if (content?.type !== "text") throw new Error("Expected text tool content")
  return content.text
}

const jsonResponse = (body: unknown): Response =>
  new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" }
  })

const requestJson = (init: RequestInit): unknown =>
  JSON.parse(expectString(init.body, "request body"))

const requestBytes = (init: RequestInit): Buffer => {
  if (!(init.body instanceof Uint8Array)) throw new Error("Expected a binary request body")
  return Buffer.from(init.body)
}

const requestHeaders = (init: RequestInit): Headers => {
  if (!(init.headers instanceof Headers)) throw new Error("Expected request Headers")
  return init.headers
}

const stubFetch = (
  responder: (url: URL, init: RequestInit) => Response | Promise<Response>
): ReturnType<typeof vi.fn> => {
  const fetchMock = vi.fn(async (input: string | URL | Request, init?: RequestInit) =>
    responder(new URL(input instanceof Request ? input.url : input.toString()), init ?? {})
  )
  vi.stubGlobal("fetch", fetchMock)
  return fetchMock
}

afterEach(() => {
  vi.unstubAllGlobals()
})

describe("Codevisor MCP provider", () => {
  it("publishes a unique, resource-oriented tool contract", async () => {
    const { tools } = makeCodevisorProvider(
      () => "http://unused",
      async () => "unused"
    )
    const names = tools.map((tool) => tool.name)
    expect(new Set(names).size).toBe(names.length)
    expect(names).toEqual(
      expect.arrayContaining([
        "context.current",
        "projects.create",
        "worktrees.create",
        "workspaces.upsert",
        "workspaces.open_plugin_pane",
        "sessions.prompt",
        "files.upload",
        "mcps.create",
        "skills.create",
        "plugins.registry_search",
        "plugins.discover_remote",
        "plugins.install",
        "plugins.open_pane_url",
        "harnesses.accounts_login",
        "machines.cloud_connect",
        "server.shutdown"
      ])
    )

    const worktree = tools.find((tool) => tool.name === "worktrees.create")!
    expect(worktree.inputSchema).toMatchObject({
      properties: { projectId: { type: "string" }, id: { anyOf: expect.any(Array) } }
    })
    expect(worktree.inputSchema.required).toBeUndefined()
    const transcript = tools.find((tool) => tool.name === "sessions.transcript")!
    expect(transcript.inputSchema).toMatchObject({
      properties: {
        sessionId: { description: "Session id. Defaults to the calling session." }
      }
    })
    const capabilities = tools.find((tool) => tool.name === "server.capabilities")!
    expect(capabilities.inputSchema).toMatchObject({
      properties: {
        cwd: { description: "Working directory used to resolve harness capabilities." }
      }
    })

    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )
    expect(
      JSON.parse(textContent(await provider.invoke(callingContext, "context.current", {})))
    ).toEqual({ sessionId: "calling session/id", projectId: "calling project/id" })
    expect(
      JSON.parse(
        textContent(await provider.invoke({ sessionId: "session-only" }, "context.current", {}))
      )
    ).toEqual({ sessionId: "session-only" })
    await expect(provider.invoke(callingContext, "missing.tool", {})).rejects.toThrow(
      "Unknown Codevisor tool"
    )
    await provider.closeSession(callingContext.sessionId)
    await provider.close()
  })

  it("applies context defaults, path aliases, and query encoding", async () => {
    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ ok: true })
    })
    const provider = makeCodevisorProvider(
      () => "http://0.0.0.0:43210",
      async () => "stable-token"
    )

    await provider.invoke(callingContext, "sessions.get", {})
    await provider.invoke(callingContext, "projects.update", { name: "Renamed" })
    await provider.invoke(callingContext, "terminals.close_session", {})
    await provider.invoke(callingContext, "sessions.transcript_details", {
      itemId: "item/id"
    })
    await provider.invoke(callingContext, "server.update_status", {
      refresh: true,
      channel: "alpha"
    })
    await provider.invoke(callingContext, "server.update_status", { refresh: false })
    await provider.invoke(callingContext, "server.update_status", {})
    await provider.invoke(callingContext, "filesystem.list", {
      path: "/tmp/a b",
      showHidden: true
    })

    expect(requests.map(({ url }) => url.pathname)).toEqual([
      "/v1/sessions/calling%20session%2Fid",
      "/v1/projects/calling%20project%2Fid",
      "/v1/terminals/session/calling%20session%2Fid",
      "/v1/sessions/calling%20session%2Fid/transcript/item%2Fid/details",
      "/v1/update",
      "/v1/update",
      "/v1/update",
      "/v1/fs/list"
    ])
    expect(requests.every(({ url }) => url.hostname === "127.0.0.1")).toBe(true)
    expect(requests[4]!.url.search).toBe("?refresh=1&channel=alpha")
    expect(requests[5]!.url.search).toBe("?refresh=false")
    expect(requests[6]!.url.search).toBe("")
    expect(requests[7]!.url.searchParams.get("showHidden")).toBe("true")
    expect(requests[0]!.init.headers).toBeInstanceOf(Headers)
    expect(requestHeaders(requests[0]!.init).get("authorization")).toBe("Bearer stable-token")
    await expect(provider.invoke(callingContext, "workspaces.delete", {})).rejects.toThrow(
      "workspaces.delete requires workspaceId"
    )
  })

  it("serializes object, wrapped, contextual, and binary request bodies", async () => {
    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ accepted: true })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )

    await provider.invoke(callingContext, "machines.cloud_connect", {
      serverUrl: "https://cloud.example",
      sessionToken: "cloud-token"
    })
    await provider.invoke(callingContext, "clients.open_page", {
      clientId: "client",
      body: { page: "home" }
    })
    await provider.invoke(callingContext, "sessions.create", {
      id: "new-session",
      harnessId: "codex"
    })
    await provider.invoke({ sessionId: "caller" }, "sessions.create", {
      id: "explicit-session",
      projectId: "explicit-project",
      workspaceId: "existing-workspace",
      parentSessionId: "explicit-parent",
      harnessId: "codex"
    })
    await provider.invoke({ sessionId: "caller" }, "sessions.create", {
      id: "unscoped-session",
      harnessId: "codex"
    })
    await provider.invoke(callingContext, "harnesses.install", { harnessId: "codex" })
    await provider.invoke(callingContext, "files.upload", {
      name: "hello.txt",
      mimeType: "text/plain",
      dataBase64: Buffer.from("hello").toString("base64")
    })
    await provider.invoke(callingContext, "files.upload", {
      dataBase64: Buffer.from("bytes").toString("base64")
    })

    expect(requestJson(requests[0]!.init)).toEqual({
      serverUrl: "https://cloud.example",
      sessionToken: "cloud-token"
    })
    expect(requestJson(requests[1]!.init)).toEqual({ page: "home" })
    expect(requestJson(requests[2]!.init)).toMatchObject({
      id: "new-session",
      projectId: "calling project/id",
      harnessId: "codex"
    })
    const created = expectRecord(requestJson(requests[2]!.init), "session body")
    const unscoped = expectRecord(requestJson(requests[4]!.init), "session body")
    expect(created.workspaceId).toMatch(/^[0-9a-f-]{36}$/)
    expect(unscoped.workspaceId).toMatch(/^[0-9a-f-]{36}$/)
    expect(unscoped.workspaceId).not.toBe(created.workspaceId)
    expect(requestJson(requests[3]!.init)).toMatchObject({
      projectId: "explicit-project",
      workspaceId: "existing-workspace",
      parentSessionId: "explicit-parent"
    })
    expect(unscoped).not.toHaveProperty("projectId")
    expect(unscoped).toMatchObject({ parentSessionId: "caller" })
    expect(requestJson(requests[5]!.init)).toEqual({})
    expect(requestBytes(requests[6]!.init).toString()).toBe("hello")
    expect(requests[6]!.url.searchParams.get("name")).toBe("hello.txt")
    expect(requests[6]!.url.searchParams.has("mimeType")).toBe(false)
    expect(requestHeaders(requests[6]!.init).get("content-type")).toBe("text/plain")
    expect(requestHeaders(requests[7]!.init).get("content-type")).toBe("application/octet-stream")
    await expect(provider.invoke(callingContext, "files.upload", {})).rejects.toThrow(
      "files.upload requires dataBase64"
    )
  })

  it("signs prompts with the calling session so a bot can tell agents from its user", async () => {
    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ accepted: true })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )

    await provider.invoke({ sessionId: "agent" }, "sessions.prompt", {
      sessionId: "bot",
      text: "done",
      fromSessionId: "someone-else"
    })

    expect(requests[0]!.url.pathname).toBe("/v1/sessions/bot/prompt")
    expect(requestJson(requests[0]!.init)).toEqual({ text: "done", fromSessionId: "agent" })
  })

  it("shortens waits to what is left of the execute budget and says so", async () => {
    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ sessions: [], timedOut: true })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )
    const signal = new AbortController().signal
    const tight = { sessionId: "agent", deadline: performance.now() + 60_000, signal }
    const roomy = { sessionId: "agent", deadline: performance.now() + 600_000 }

    const clamped = await provider.invoke(tight, "sessions.wait", {
      ids: ["child"],
      timeoutMs: 300_000
    })
    const untouched = await provider.invoke(roomy, "jobs.wait", { jobId: "j1", timeoutMs: 1_000 })

    const sentTimeout = expectRecord(requestJson(requests[0]!.init), "wait body").timeoutMs
    expect(sentTimeout).toBeGreaterThan(50_000)
    expect(sentTimeout).toBeLessThanOrEqual(58_500)
    expect(requests[0]!.init.signal).toBe(signal)
    expect(JSON.parse(textContent(clamped))).toEqual({
      sessions: [],
      timedOut: true,
      clampedToMs: sentTimeout
    })
    expect(requests[1]!.url.pathname).toBe("/v1/jobs/j1/wait")
    expect(requestJson(requests[1]!.init)).toEqual({ timeoutMs: 1_000 })
    expect(JSON.parse(textContent(untouched))).toEqual({ sessions: [], timedOut: true })
  })

  it("gates consent-marked tools on an explicit confirm argument", async () => {
    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ id: "codevisor.git-diff" })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )
    const install = provider.tools.find((tool) => tool.name === "plugins.install")!
    expect(install.inputSchema.required).toContain("confirm")
    expect(install.inputSchema).toMatchObject({
      properties: { source: { type: "string" }, confirm: { type: "boolean" } }
    })

    await expect(
      provider.invoke(callingContext, "plugins.install", { source: "owner/repo" })
    ).rejects.toThrow("plugins.install requires confirm: true")
    await expect(
      provider.invoke(callingContext, "plugins.install", { source: "owner/repo", confirm: false })
    ).rejects.toThrow("explicit approval")
    expect(requests).toHaveLength(0)

    await provider.invoke(callingContext, "plugins.install", {
      source: "owner/repo",
      confirm: true
    })
    expect(requests[0]!.url.pathname).toBe("/v1/plugins/import-remote")
    expect(requestJson(requests[0]!.init)).toEqual({ source: "owner/repo" })
  })

  it("returns binary, empty, JSON, and plain-text API responses", async () => {
    const responses = [
      new Response(Buffer.from("first"), { headers: { "content-type": "text/example" } }),
      new Response(Buffer.from("second")),
      new Response(null, { status: 204 }),
      jsonResponse({ healthy: true }),
      new Response("plain response", { headers: { "content-type": "text/plain" } }),
      new Response(new Uint8Array(Buffer.from("bare response")))
    ]
    stubFetch(() => responses.shift()!)
    const provider = makeCodevisorProvider(
      () => "http://[::]:43210",
      async () => "stable-token"
    )

    const first = await provider.invoke(callingContext, "files.download", { fileId: "first" })
    const second = await provider.invoke(callingContext, "files.download", { fileId: "second" })
    expect(first.content[0]).toMatchObject({
      type: "resource",
      resource: { mimeType: "text/example", blob: Buffer.from("first").toString("base64") }
    })
    expect(second.content[0]).toMatchObject({
      type: "resource",
      resource: {
        mimeType: "application/octet-stream",
        blob: Buffer.from("second").toString("base64")
      }
    })
    expect(
      JSON.parse(textContent(await provider.invoke(callingContext, "server.shutdown", {})))
    ).toEqual({ ok: true, status: 204 })
    expect(
      JSON.parse(textContent(await provider.invoke(callingContext, "server.health", {})))
    ).toEqual({ healthy: true })
    expect(textContent(await provider.invoke(callingContext, "server.info", {}))).toBe(
      "plain response"
    )
    expect(textContent(await provider.invoke(callingContext, "server.discovery", {}))).toBe(
      "bare response"
    )
  })

  it("surfaces structured, unstructured, and empty HTTP failures", async () => {
    const responses = [
      new Response(JSON.stringify({ error: "invalid request" }), {
        status: 400,
        statusText: "Bad Request"
      }),
      new Response(JSON.stringify({ error: 42 }), { status: 401, statusText: "" }),
      new Response("plain failure", { status: 500, statusText: "Failure" }),
      new Response(null, { status: 503, statusText: "" })
    ]
    stubFetch(() => responses.shift()!)
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )

    await expect(provider.invoke(callingContext, "server.health", {})).rejects.toThrow(
      "server.health failed (400 Bad Request): invalid request"
    )
    await expect(provider.invoke(callingContext, "server.health", {})).rejects.toThrow(
      'server.health failed (401): {"error":42}'
    )
    await expect(provider.invoke(callingContext, "server.health", {})).rejects.toThrow(
      "server.health failed (500 Failure): plain failure"
    )
    await expect(provider.invoke(callingContext, "server.health", {})).rejects.toThrow(
      "server.health failed (503): Codevisor request failed"
    )
  })

  it("keeps coded failures typed so sandbox code can catch them by class", async () => {
    const responses = [
      jsonResponse({
        error: {
          message: "Studio side is not attached",
          code: "client_unavailable",
          details: { clientId: "window-2", name: "Studio side", phase: "before-send" }
        }
      }),
      jsonResponse({ error: "Slow down", code: "rate_limited", details: null })
    ]
    stubFetch(() => {
      const response = responses.shift()!
      return new Response(response.body, { status: 409, statusText: "Conflict" })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )

    const unavailable = await provider
      .invoke(callingContext, "clients.context", { clientId: "window-2" })
      .catch((error: unknown) => error)
    expect(unavailable).toBeInstanceOf(CodeExecutionToolError)
    expect(unavailable).toMatchObject({
      message: "Studio side is not attached",
      code: "client_unavailable",
      details: { clientId: "window-2", name: "Studio side", phase: "before-send" }
    })
    const limited = await provider
      .invoke(callingContext, "server.health", {})
      .catch((error: unknown) => error)
    expect(limited).toBeInstanceOf(CodeExecutionToolError)
    expect(limited).toMatchObject({ message: "Slow down", code: "rate_limited" })
    if (!(limited instanceof CodeExecutionToolError)) throw new Error("Expected a tool error")
    expect(limited.details).toBeUndefined()
  })

  it("reports the calling workspace, machine, parent session, and origin client from context.current", async () => {
    const seen: Array<AutomationProviderContext> = []
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token",
      {
        currentContext: async (context) => {
          seen.push(context)
          return {
            workspaceId: "workspace-1",
            worktreeName: "retry-fix",
            parentSessionId: "parent-session",
            machine: { id: "studio", name: "Mac Studio" },
            clientId: "window-2"
          }
        }
      }
    )

    expect(
      JSON.parse(textContent(await provider.invoke(callingContext, "context.current", {})))
    ).toEqual({
      sessionId: "calling session/id",
      projectId: "calling project/id",
      workspaceId: "workspace-1",
      worktreeName: "retry-fix",
      parentSessionId: "parent-session",
      machine: { id: "studio", name: "Mac Studio" },
      clientId: "window-2"
    })
    expect(seen).toEqual([callingContext])
  })
})
