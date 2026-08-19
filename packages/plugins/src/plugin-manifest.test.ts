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
        idleTimeoutSeconds: 0,
        install: { command: "bun install" },
        panes: [{ icon: "sparkles", path: "/x/", title: "X", type: "x" }],
        platforms: ["darwin"]
      })
    )
    expect(manifest.install?.command).toBe("bun install")
    expect(manifest.idleTimeoutSeconds).toBe(0)
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

  it("rejects negative or fractional idle timeouts", () => {
    expectInvalid({ ...validManifest, idleTimeoutSeconds: -1 }, "idleTimeoutSeconds")
    expectInvalid({ ...validManifest, idleTimeoutSeconds: 1.5 }, "idleTimeoutSeconds")
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
