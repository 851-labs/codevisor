import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { AutomationProviderContext } from "./automation-provider.js"
import { codevisorTools, makeCodevisorProvider } from "./codevisor-provider.js"

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
    const names = codevisorTools.map((tool) => tool.name)
    expect(names).toHaveLength(129)
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
        "plugins.discover_remote",
        "plugins.install",
        "plugins.open_pane_url",
        "harnesses.accounts_login",
        "machines.cloud_connect",
        "server.shutdown"
      ])
    )

    const worktree = codevisorTools.find((tool) => tool.name === "worktrees.create")!
    expect(worktree.inputSchema).toMatchObject({
      properties: { projectId: { type: "string" }, id: { anyOf: expect.any(Array) } }
    })
    expect(worktree.inputSchema.required).toBeUndefined()
    const transcript = codevisorTools.find((tool) => tool.name === "sessions.transcript")!
    expect(transcript.inputSchema).toMatchObject({
      properties: {
        sessionId: { description: "Session id. Defaults to the calling session." },
        before: { description: "Exclusive transcript cursor." }
      }
    })
    const capabilities = codevisorTools.find((tool) => tool.name === "server.capabilities")!
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
    expect((requests[0]!.init.headers as Headers).get("authorization")).toBe("Bearer stable-token")
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
    await provider.invoke(callingContext, "harnesses.custom_replace", { body: [] })
    await provider.invoke(callingContext, "sessions.create", {
      id: "new-session",
      harnessId: "codex"
    })
    await provider.invoke({ sessionId: "caller" }, "sessions.create", {
      id: "explicit-session",
      projectId: "explicit-project",
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

    expect(JSON.parse(requests[0]!.init.body as string)).toEqual({
      serverUrl: "https://cloud.example",
      sessionToken: "cloud-token"
    })
    expect(JSON.parse(requests[1]!.init.body as string)).toEqual([])
    expect(JSON.parse(requests[2]!.init.body as string)).toMatchObject({
      id: "new-session",
      projectId: "calling project/id",
      harnessId: "codex"
    })
    expect(JSON.parse(requests[3]!.init.body as string).projectId).toBe("explicit-project")
    expect(JSON.parse(requests[4]!.init.body as string)).not.toHaveProperty("projectId")
    expect(JSON.parse(requests[5]!.init.body as string)).toEqual({})
    expect(Buffer.from(requests[6]!.init.body as ArrayBuffer).toString()).toBe("hello")
    expect(requests[6]!.url.searchParams.get("name")).toBe("hello.txt")
    expect(requests[6]!.url.searchParams.has("mimeType")).toBe(false)
    expect((requests[6]!.init.headers as Headers).get("content-type")).toBe("text/plain")
    expect((requests[7]!.init.headers as Headers).get("content-type")).toBe(
      "application/octet-stream"
    )
    await expect(provider.invoke(callingContext, "files.upload", {})).rejects.toThrow(
      "files.upload requires dataBase64"
    )
  })

  it("gates consent-marked tools on an explicit confirm argument", async () => {
    const install = codevisorTools.find((tool) => tool.name === "plugins.install")!
    expect(install.inputSchema.required).toContain("confirm")
    expect(install.inputSchema).toMatchObject({
      properties: { source: { type: "string" }, confirm: { type: "boolean" } }
    })

    const requests: Array<{ url: URL; init: RequestInit }> = []
    stubFetch((url, init) => {
      requests.push({ url, init })
      return jsonResponse({ id: "codevisor.git-diff" })
    })
    const provider = makeCodevisorProvider(
      () => "http://localhost:43210",
      async () => "stable-token"
    )

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
    // The consent argument is local to the tool; the server never sees it.
    expect(JSON.parse(requests[0]!.init.body as string)).toEqual({ source: "owner/repo" })
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
})
