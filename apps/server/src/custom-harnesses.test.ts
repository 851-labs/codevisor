import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  customHarnessDefinition,
  customHarnessesPath,
  loadCustomHarnesses,
  parseCustomHarnessDocument,
  saveCustomHarnesses
} from "./custom-harnesses.js"

const roots: Array<string> = []

const makeRoot = (): string => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-custom-harnesses-"))
  roots.push(root)
  return root
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true })
})

describe("custom harnesses", () => {
  it("loads a valid wrapper document", async () => {
    const root = makeRoot()
    writeFileSync(
      customHarnessesPath(root),
      JSON.stringify({
        harnesses: [
          {
            id: "my-agent",
            name: "My Agent",
            command: "/opt/agents/my-agent",
            args: ["acp"],
            env: { MY_AGENT_DEBUG: "1" }
          }
        ]
      })
    )

    const result = await loadCustomHarnesses(root)
    expect(result.warnings).toEqual([])
    expect(result.specs).toEqual([
      {
        args: ["acp"],
        command: "/opt/agents/my-agent",
        env: { MY_AGENT_DEBUG: "1" },
        id: "my-agent",
        name: "My Agent"
      }
    ])
    expect(result.definitions[0]).toMatchObject({
      detectBinaries: ["/opt/agents/my-agent"],
      id: "my-agent",
      launch: {
        args: ["acp"],
        command: "/opt/agents/my-agent",
        env: { MY_AGENT_DEBUG: "1" },
        kind: "executable"
      },
      provider: "acp",
      symbolName: "puzzlepiece.extension"
    })
  })

  it("accepts a bare top-level array", () => {
    const result = parseCustomHarnessDocument(
      [{ id: "solo", name: "Solo", command: "solo-agent" }],
      "test"
    )
    expect(result.warnings).toEqual([])
    expect(result.specs).toHaveLength(1)
  })

  it("skips malformed entries with warnings instead of failing", () => {
    const result = parseCustomHarnessDocument(
      {
        harnesses: [
          "not-an-object",
          { id: "bad id!", name: "Bad", command: "x" },
          { id: "no-name", name: "   ", command: "x" },
          { id: "no-command", name: "No Command", command: "" },
          { id: "bad-args", name: "Bad Args", command: "x", args: [1] },
          { id: "bad-env", name: "Bad Env", command: "x", env: { a: 1 } },
          { id: "ok", name: "OK", command: "ok-agent" }
        ]
      },
      "test"
    )
    expect(result.specs.map((spec) => spec.id)).toEqual(["ok"])
    expect(result.warnings).toHaveLength(6)
  })

  it("skips builtin collisions and duplicate ids", () => {
    const result = parseCustomHarnessDocument(
      {
        harnesses: [
          { id: "codex", name: "Fake Codex", command: "fake-codex" },
          { id: "mine", name: "Mine", command: "mine" },
          { id: "mine", name: "Mine Again", command: "mine2" }
        ]
      },
      "test"
    )
    expect(result.specs.map((spec) => spec.id)).toEqual(["mine"])
    expect(result.warnings).toEqual([
      expect.stringContaining("collides with a builtin"),
      expect.stringContaining("duplicate id")
    ])
  })

  it("returns empty for a missing file and warns on invalid JSON", async () => {
    const root = makeRoot()
    expect(await loadCustomHarnesses(root)).toEqual({
      definitions: [],
      specs: [],
      warnings: []
    })

    writeFileSync(customHarnessesPath(root), "{ not json")
    const invalid = await loadCustomHarnesses(root)
    expect(invalid.specs).toEqual([])
    expect(invalid.warnings).toEqual([expect.stringContaining("invalid JSON")])
  })

  it("warns on valid JSON with the wrong shape and on unreadable files", async () => {
    expect(parseCustomHarnessDocument({ harnesses: "nope" }, "test").warnings).toEqual([
      expect.stringContaining('expected { "harnesses": [...] }')
    ])

    // A directory at the file's path fails with EISDIR, not ENOENT — that is
    // a warning, never a crash.
    const root = makeRoot()
    mkdirSync(customHarnessesPath(root))
    const unreadable = await loadCustomHarnesses(root)
    expect(unreadable.specs).toEqual([])
    expect(unreadable.warnings).toEqual([expect.stringContaining("unreadable")])
  })

  it("round-trips through save and load", async () => {
    const root = makeRoot()
    const specs = [
      { command: "agent-one", id: "one", name: "One" },
      { args: ["--acp"], command: "agent-two", id: "two", name: "Two" }
    ]
    await saveCustomHarnesses(root, specs)
    const loaded = await loadCustomHarnesses(root)
    expect(loaded.warnings).toEqual([])
    expect(loaded.specs).toEqual(specs)
  })

  it("maps a minimal spec to an executable ACP definition", () => {
    expect(customHarnessDefinition({ command: "mini", id: "mini", name: "Mini" })).toEqual({
      detectBinaries: ["mini"],
      id: "mini",
      launch: { args: [], command: "mini", kind: "executable" },
      name: "Mini",
      provider: "acp",
      symbolName: "puzzlepiece.extension"
    })
  })
})
