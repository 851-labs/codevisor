import { writeFileSync } from "node:fs"
import { cp } from "node:fs/promises"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { PluginsError } from "./plugins-error.js"
import { exampleManifest, makeDir, makeManager, toolManifest, writePlugin } from "./test-support.js"

/// Agent-tool surface of the manager: flattened tool listings, the invocation
/// path (running-process reuse, signed context, typed failures), and the installed-set
/// subscription that keeps the MCP gateway's advertised tools fresh.

const invalid = async (
  attempt: Promise<unknown>,
  code: PluginsError["code"],
  messagePart: string | RegExp
): Promise<void> => {
  try {
    await attempt
    expect.unreachable("invocation should have failed")
  } catch (cause) {
    expect(cause).toBeInstanceOf(PluginsError)
    expect((cause as PluginsError).code).toBe(code)
    expect((cause as PluginsError).message).toMatch(messagePart)
  }
}

describe("plugin tool listing", () => {
  it("flattens declared tools across plugins and carries them in summaries", async () => {
    const { manager, root } = makeManager({}, toolManifest)
    writePlugin(root, "toolless", exampleManifest)
    const tools = await manager.listTools()
    expect(tools.map((tool) => tool.pluginId)).toEqual(Array(7).fill("owner.notes"))
    const add = tools.find((tool) => tool.name === "notes_add")
    expect(add?.description).toBe("Append a note")
    expect(add?.inputSchema).toMatchObject({ type: "object" })
    // Tools without a declared schema stay schemaless (agents get "any").
    expect(tools.find((tool) => tool.name === "notes_list")?.inputSchema).toBeUndefined()

    const list = await manager.list()
    const notes = list.plugins.find((plugin) => plugin.id === "owner.notes")
    expect(notes?.panes).toHaveLength(0)
    expect(notes?.tools).toHaveLength(7)
    expect(list.plugins.find((plugin) => plugin.id === "owner.example")?.tools).toBeUndefined()
  })
})

describe("plugin tool invocation", () => {
  it("POSTs JSON arguments with signed context headers and parses the response", async () => {
    const { fake, manager } = makeManager({}, toolManifest)
    const result = await manager.invokeTool(
      "owner.notes",
      "notes_add",
      { text: "hi" },
      { cwd: "/tmp/project", workspaceId: "w1" }
    )
    expect(result).toEqual({ ok: true, received: { text: "hi" } })
    const seen = fake.requests[0]
    expect(seen?.method).toBe("POST")
    expect(seen?.path).toBe("/tools/add")
    expect(seen?.body).toBe(JSON.stringify({ text: "hi" }))
    expect(seen?.headers["content-type"]).toBe("application/json")
    expect(seen?.headers["x-codevisor-context-signature"]).toBeDefined()
    const context = JSON.parse(
      Buffer.from(String(seen?.headers["x-codevisor-context"]), "base64").toString("utf8")
    ) as Record<string, unknown>
    expect(context).toEqual({
      cwd: "/tmp/project",
      pluginId: "owner.notes",
      toolName: "notes_add",
      workspaceId: "w1"
    })
  })

  it("defaults the caller context to empty", async () => {
    const { fake, manager } = makeManager({}, toolManifest)
    await manager.invokeTool("owner.notes", "notes_add", {})
    const context = JSON.parse(
      Buffer.from(String(fake.requests[0]?.headers["x-codevisor-context"]), "base64").toString(
        "utf8"
      )
    ) as Record<string, unknown>
    expect(context).toEqual({ pluginId: "owner.notes", toolName: "notes_add" })
  })

  it("returns non-JSON responses as text", async () => {
    const { manager } = makeManager({}, toolManifest)
    await expect(manager.invokeTool("owner.notes", "notes_list", {})).resolves.toBe("two notes")
    // Responses with no content type at all also come back as raw text.
    await expect(manager.invokeTool("owner.notes", "notes_untyped", {})).resolves.toBe("untyped")
  })

  it("maps tool failures onto typed errors", async () => {
    const { manager } = makeManager({}, toolManifest)
    await invalid(manager.invokeTool("owner.notes", "notes_fail", {}), "invalid", /HTTP 500.*boom/)
    // Empty error bodies keep the message clean (no trailing colon).
    await invalid(
      manager.invokeTool("owner.notes", "notes_missing", {}),
      "invalid",
      /failed \(HTTP 404\)$/
    )
    await invalid(
      manager.invokeTool("owner.notes", "notes_bad_json", {}),
      "invalid",
      /returned invalid JSON/
    )
  })

  it("404s unknown tools, tool-less plugins, and unknown plugins", async () => {
    const { manager, root } = makeManager({}, toolManifest)
    writePlugin(root, "toolless", exampleManifest)
    await invalid(manager.invokeTool("owner.notes", "nope", {}), "notFound", /has no tool: nope/)
    await invalid(
      manager.invokeTool("owner.example", "notes_add", {}),
      "notFound",
      /has no tool: notes_add/
    )
    await invalid(manager.invokeTool("owner.ghost", "notes_add", {}), "notFound", /not installed/)
  })

  it("times out hung tools without kicking the runtime", async () => {
    const { manager } = makeManager({ toolTimeoutMs: 100 }, toolManifest)
    await invalid(
      manager.invokeTool("owner.notes", "notes_slow", {}),
      "unavailable",
      /did not respond within 100ms/
    )
    // The process is alive but was hung — the same instance keeps serving.
    await expect(manager.invokeTool("owner.notes", "notes_add", {})).resolves.toMatchObject({
      ok: true
    })
  })

  it("kicks the runtime when the port is dead so the next call relaunches", async () => {
    const { fake, manager } = makeManager({ backoffBaseMs: 0 }, toolManifest)
    await manager.invokeTool("owner.notes", "notes_add", {})
    fake.stop()
    await invalid(
      manager.invokeTool("owner.notes", "notes_add", {}),
      "unavailable",
      /request failed/
    )
    // markUnreachable registered the failure; with no backoff the next
    // invocation relaunches the plugin and succeeds.
    await expect(manager.invokeTool("owner.notes", "notes_add", {})).resolves.toMatchObject({
      ok: true
    })
  })
})

describe("tool discovery", () => {
  it("surfaces declared tools in remote discovery for the consent step", async () => {
    const fixture = makeDir("codevisor-plugin-tool-discover-")
    writeFileSync(join(fixture, "codevisor-plugin.json"), JSON.stringify(toolManifest))
    const { manager } = makeManager({
      clone: (url, _ref, destination) => cp(url, destination, { recursive: true })
    })
    const discovered = await manager.discoverRemote({ source: fixture })
    expect(discovered.tools).toHaveLength(7)
    expect(discovered.tools?.[0]).toMatchObject({ description: "Append a note", name: "notes_add" })
  })
})

describe("installed-set subscription", () => {
  it("notifies on link, import, and remove — and honors unsubscribes", async () => {
    const fixture = makeDir("codevisor-plugin-tool-fixture-")
    writeFileSync(
      join(fixture, "codevisor-plugin.json"),
      JSON.stringify({ ...exampleManifest, id: "owner.fresh", name: "Fresh" })
    )
    const { manager } = makeManager({
      clone: (url, _ref, destination) => cp(url, destination, { recursive: true })
    })
    let notified = 0
    const unsubscribe = manager.subscribeInstalled(() => {
      notified += 1
    })
    await manager.importRemote({ source: fixture })
    expect(notified).toBe(1)
    await manager.remove("owner.fresh")
    expect(notified).toBe(2)

    const linkTarget = makeDir("codevisor-plugin-tool-link-")
    writeFileSync(
      join(linkTarget, "codevisor-plugin.json"),
      JSON.stringify({ ...exampleManifest, id: "owner.linked", name: "Linked" })
    )
    await manager.link({ path: linkTarget })
    expect(notified).toBe(3)

    unsubscribe()
    await manager.importRemote({ source: fixture })
    expect(notified).toBe(3)
  })
})
