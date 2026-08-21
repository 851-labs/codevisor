import { describe, expect, it } from "vitest"
import { parsePluginManifest } from "./plugin-manifest.js"
import { PluginsError } from "./plugins-error.js"

const validManifest = {
  id: "owner.example",
  name: "Example",
  panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
  protocolVersion: 1,
  run: { command: "bun run start" },
  version: "0.1.0"
}

const expectInvalid = (manifest: unknown, messagePart: string): void => {
  try {
    parsePluginManifest(JSON.stringify(manifest))
    expect.unreachable("manifest should have been rejected")
  } catch (cause) {
    expect(cause).toBeInstanceOf(PluginsError)
    expect((cause as PluginsError).code).toBe("invalid")
    expect((cause as PluginsError).message).toContain(messagePart)
  }
}

describe("parsePluginManifest", () => {
  it("parses a valid manifest", () => {
    const manifest = parsePluginManifest(JSON.stringify(validManifest))
    expect(manifest.id).toBe("owner.example")
    expect(manifest.panes).toHaveLength(1)
  })

  it("accepts optional fields", () => {
    const manifest = parsePluginManifest(
      JSON.stringify({
        ...validManifest,
        description: "A plugin",
        healthPath: "/health",
        iconPath: "/assets/plugin.svg",
        install: { command: "bun install" },
        panes: [{ iconPath: "/assets/pane.webp", path: "/x/", title: "X", type: "x" }],
        platforms: ["darwin"]
      })
    )
    expect(manifest.install?.command).toBe("bun install")
    expect(manifest.iconPath).toBe("/assets/plugin.svg")
  })

  it("rejects non-JSON payloads", () => {
    expect(() => parsePluginManifest("not json")).toThrow(/not valid JSON/)
  })

  it("rejects schema mismatches", () => {
    expectInvalid({ id: "owner.example" }, "Invalid plugin manifest")
  })

  it("rejects unsupported protocol versions", () => {
    expectInvalid({ ...validManifest, protocolVersion: 2 }, "Unsupported plugin protocolVersion")
  })

  it("rejects ids that are not owner.name shaped", () => {
    expectInvalid({ ...validManifest, id: "Example" }, "owner.name")
    expectInvalid({ ...validManifest, id: "owner.name.extra" }, "owner.name")
    expectInvalid({ ...validManifest, id: "owner/../name" }, "owner.name")
  })

  it("rejects empty run commands", () => {
    expectInvalid({ ...validManifest, run: { command: "  " } }, "run.command")
  })

  it("rejects icon paths that are not plain absolute server paths", () => {
    expectInvalid({ ...validManifest, iconPath: "icon.svg" }, "Plugin iconPath")
    expectInvalid({ ...validManifest, iconPath: "/icons/../icon.svg" }, "Plugin iconPath")
    expectInvalid(
      {
        ...validManifest,
        panes: [{ iconPath: "/icon.svg?dark", path: "/x/", title: "X", type: "x" }]
      },
      "Pane x iconPath"
    )
  })

  it("rejects duplicate pane types", () => {
    expectInvalid(
      {
        ...validManifest,
        panes: [
          { path: "/a/", title: "A", type: "a" },
          { path: "/b/", title: "B", type: "a" }
        ]
      },
      "Duplicate pane type"
    )
  })

  it("rejects pane paths without slash discipline", () => {
    expectInvalid(
      { ...validManifest, panes: [{ path: "panes/", title: "A", type: "a" }] },
      "start and end"
    )
    expectInvalid(
      { ...validManifest, panes: [{ path: "/panes", title: "A", type: "a" }] },
      "start and end"
    )
  })

  it("parses tool declarations, including tool-only plugins", () => {
    const manifest = parsePluginManifest(
      JSON.stringify({
        ...validManifest,
        panes: [],
        tools: [
          {
            description: "Append a note",
            inputSchema: { properties: { text: { type: "string" } }, type: "object" },
            name: "notes_add",
            path: "/tools/add"
          },
          // No trailing slash required and no inputSchema — both optional.
          { description: "List notes", name: "notes_list", path: "/tools/list" }
        ]
      })
    )
    expect(manifest.panes).toHaveLength(0)
    expect(manifest.tools).toHaveLength(2)
    expect(manifest.tools?.[0]?.inputSchema).toMatchObject({ type: "object" })
  })

  const tool = (overrides: Record<string, unknown>): Record<string, unknown> => ({
    ...validManifest,
    tools: [{ description: "A tool", name: "tool_a", path: "/tools/a", ...overrides }]
  })

  it("rejects tool names outside the lowercase [a-z0-9_]+ grammar", () => {
    expectInvalid(tool({ name: "Notes.Add" }), "lowercase letters, digits, and underscores")
    expectInvalid(tool({ name: "" }), "lowercase letters, digits, and underscores")
  })

  it("rejects duplicate tool names", () => {
    expectInvalid(
      {
        ...validManifest,
        tools: [
          { description: "A", name: "tool_a", path: "/a" },
          { description: "B", name: "tool_a", path: "/b" }
        ]
      },
      "Duplicate tool name"
    )
  })

  it("rejects blank tool descriptions", () => {
    expectInvalid(tool({ description: "  " }), "non-empty description")
  })

  it("rejects tool paths that are not plain absolute paths", () => {
    expectInvalid(tool({ path: "tools/a" }), "plain absolute path")
    expectInvalid(tool({ path: "/tools/../a" }), "plain absolute path")
    expectInvalid(tool({ path: "/tools/a?x" }), "plain absolute path")
    expectInvalid(tool({ path: "/tools/a#x" }), "plain absolute path")
  })

  it("rejects non-object tool input schemas", () => {
    expectInvalid(tool({ inputSchema: "string" }), "inputSchema must be a JSON object")
    expectInvalid(tool({ inputSchema: null }), "inputSchema must be a JSON object")
    expectInvalid(tool({ inputSchema: ["array"] }), "inputSchema must be a JSON object")
  })

  it("rejects pane paths with traversal or query fragments", () => {
    expectInvalid(
      { ...validManifest, panes: [{ path: "/../x/", title: "A", type: "a" }] },
      "plain absolute path"
    )
    expectInvalid(
      { ...validManifest, panes: [{ path: "/x/?y/", title: "A", type: "a" }] },
      "plain absolute path"
    )
    expectInvalid(
      { ...validManifest, panes: [{ path: "/x/#y/", title: "A", type: "a" }] },
      "plain absolute path"
    )
  })
})
