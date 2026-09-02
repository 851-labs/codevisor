import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupNativeMcpTests,
  run,
  HOME,
  testManager,
  harnessGroup
} from "./native-mcp-test-support.js"

afterEach(cleanupNativeMcpTests)

describe("destructive native operations", () => {
  // A ~/.claude.json fixture with unrelated state, comments, and 4-space
  // indentation — removal must leave everything but the one entry untouched.
  const CLAUDE_FIXTURE = `{
    // personal settings — do not lose this comment
    "numStartups": 42,
    "mcpServers": {
        "docs": {
            "command": "npx",
            "args": ["-y", "docs-mcp"],
            "env": { "TOKEN": "secret" }
        },
        "linear": {
            "type": "http",
            "url": "https://mcp.linear.app/mcp"
        }
    },
    "projects": { "/Users/u/app": { "history": ["one"] } }
}`

  const CODEX_FIXTURE = `# Codex configuration
model = "gpt-5.2-codex"

[mcp_servers.docs]
command = "npx"
args = ["-y", "docs-mcp"]

[mcp_servers.docs.env]
TOKEN = "secret"

# keep me: linear notes
[mcp_servers.linear]
url = "https://mcp.linear.app/mcp"

[profiles.fast]
model = "gpt-5.1"
`

  it("removes a claude-code entry surgically, preserving comments and unrelated keys", async () => {
    const files: Record<string, string | Error> = { [`${HOME}/.claude.json`]: CLAUDE_FIXTURE }
    const { manager } = await testManager(files)
    const result = await manager.removeServer("claude-code", "docs")
    expect(result.removal).toMatchObject({
      configPath: `${HOME}/.claude.json`,
      harnessId: "claude-code",
      serverName: "docs"
    })
    const after = files[`${HOME}/.claude.json`] as string
    expect(after).toContain("// personal settings — do not lose this comment")
    expect(after).toContain('"numStartups": 42')
    expect(after).toContain('"projects": { "/Users/u/app": { "history": ["one"] } }')
    expect(after).toContain('"linear"')
    expect(after).not.toContain("docs-mcp")
    // 4-space indentation preserved.
    expect(after).toContain('    "mcpServers"')
    const scanned = harnessGroup(result.scan, "claude-code")
    expect(scanned.servers.map((server) => server.serverName)).toEqual(["linear"])
  })

  it("removing the last entry leaves an empty map, not a deleted key", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.gemini/settings.json`]: JSON.stringify(
        { mcpServers: { docs: { command: "docs-mcp" } } },
        null,
        2
      )
    }
    const { manager } = await testManager(files)
    await manager.removeServer("gemini", "docs")
    const after = JSON.parse(files[`${HOME}/.gemini/settings.json`] as string) as Record<
      string,
      unknown
    >
    expect(after["mcpServers"]).toEqual({})
  })

  it("excises codex tables (including subtables) and preserves surrounding TOML", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.codex/config.toml`]: CODEX_FIXTURE
    }
    const { manager } = await testManager(files)
    const result = await manager.removeServer("codex", "docs")
    const after = files[`${HOME}/.codex/config.toml`] as string
    expect(after).toContain("# Codex configuration")
    expect(after).toContain('model = "gpt-5.2-codex"')
    expect(after).toContain("# keep me: linear notes")
    expect(after).toContain("[mcp_servers.linear]")
    expect(after).toContain("[profiles.fast]")
    expect(after).not.toContain("docs-mcp")
    expect(after).not.toContain("[mcp_servers.docs.env]")
    expect(harnessGroup(result.scan, "codex").servers.map((s) => s.serverName)).toEqual(["linear"])
  })

  it("refuses to edit codex entries defined as inline tables", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.codex/config.toml`]: `[mcp_servers]
docs = { command = "docs-mcp" }
`
    }
    const { manager } = await testManager(files)
    await expect(manager.removeServer("codex", "docs")).rejects.toMatchObject({
      code: "unsupported"
    })
    // The file is untouched after the refusal.
    expect(files[`${HOME}/.codex/config.toml`]).toContain('docs = { command = "docs-mcp" }')
  })

  it("takes exactly one backup per file, before the first mutation", async () => {
    const files: Record<string, string | Error> = { [`${HOME}/.claude.json`]: CLAUDE_FIXTURE }
    const { db, manager } = await testManager(files)
    await manager.removeServer("claude-code", "docs")
    const backup = await run(db.getNativeConfigBackup(`${HOME}/.claude.json`))
    expect(backup).toBeDefined()
    // The backup holds the pre-mutation content.
    expect(files[backup!.backupPath]).toBe(CLAUDE_FIXTURE)

    await manager.removeServer("claude-code", "linear")
    const backupAgain = await run(db.getNativeConfigBackup(`${HOME}/.claude.json`))
    expect(backupAgain?.backupPath).toBe(backup?.backupPath)
    expect(files[backup!.backupPath]).toBe(CLAUDE_FIXTURE)
  })

  it("restores a parked removal and marks it restored", async () => {
    const files: Record<string, string | Error> = { [`${HOME}/.claude.json`]: CLAUDE_FIXTURE }
    const { manager } = await testManager(files)
    const { removal } = await manager.removeServer("claude-code", "docs")
    expect(await manager.listRemovals()).toHaveLength(1)

    const scan = await manager.restoreRemoval(removal.id)
    const after = files[`${HOME}/.claude.json`] as string
    expect(after).toContain("docs-mcp")
    expect(after).toContain('"TOKEN": "secret"')
    expect(after).toContain("// personal settings — do not lose this comment")
    expect(
      harnessGroup(scan, "claude-code")
        .servers.map((server) => server.serverName)
        .sort()
    ).toEqual(["docs", "linear"])
    expect(await manager.listRemovals()).toHaveLength(0)
    await expect(manager.restoreRemoval(removal.id)).rejects.toMatchObject({
      code: "notFound"
    })
  })

  it("restores codex removals by appending a verified table", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.codex/config.toml`]: CODEX_FIXTURE
    }
    const { manager } = await testManager(files)
    const { removal } = await manager.removeServer("codex", "docs")
    const scan = await manager.restoreRemoval(removal.id)
    const after = files[`${HOME}/.codex/config.toml`] as string
    expect(after).toContain("# Codex configuration")
    expect(after).toContain("docs-mcp")
    expect(
      harnessGroup(scan, "codex")
        .servers.map((server) => server.serverName)
        .sort()
    ).toEqual(["docs", "linear"])
  })

  it("restores into a file that was deleted or stripped in the meantime", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.gemini/settings.json`]: JSON.stringify(
        { mcpServers: { docs: { command: "docs-mcp" } } },
        null,
        2
      )
    }
    const { manager } = await testManager(files)
    const { removal } = await manager.removeServer("gemini", "docs")
    // The user deleted the whole file after the removal.
    delete files[`${HOME}/.gemini/settings.json`]
    const scan = await manager.restoreRemoval(removal.id)
    const after = JSON.parse(files[`${HOME}/.gemini/settings.json`] as string) as Record<
      string,
      unknown
    >
    expect(after).toEqual({ mcpServers: { docs: { command: "docs-mcp" } } })
    expect(harnessGroup(scan, "gemini").servers.map((s) => s.serverName)).toEqual(["docs"])
  })

  it("refuses to restore into a changed file when the name is back in use", async () => {
    const files: Record<string, string | Error> = { [`${HOME}/.claude.json`]: CLAUDE_FIXTURE }
    const { manager } = await testManager(files)
    const { removal } = await manager.removeServer("claude-code", "docs")
    // The user re-added a server named docs behind our back.
    files[`${HOME}/.claude.json`] = JSON.stringify({
      mcpServers: { docs: { command: "other-docs" } }
    })
    await expect(manager.restoreRemoval(removal.id)).rejects.toMatchObject({ code: "conflict" })
    // Still parked for later.
    expect(await manager.listRemovals()).toHaveLength(1)
  })

  it("toggles opencode's enabled flag and cline's inverted disabled flag", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.config/opencode/opencode.json`]: JSON.stringify(
        { mcp: { local: { command: ["bun", "server.ts"], type: "local" } } },
        null,
        2
      ),
      [`${HOME}/.cline/data/settings/cline_mcp_settings.json`]: JSON.stringify(
        { mcpServers: { docs: { command: "docs-mcp" } } },
        null,
        2
      )
    }
    const { manager } = await testManager(files)

    // Unknown server in an existing config file.
    await expect(manager.setNativeEnabled("opencode", "ghost", true)).rejects.toMatchObject({
      code: "notFound"
    })

    const openScan = await manager.setNativeEnabled("opencode", "local", false)
    const opencodeAfter = JSON.parse(files[`${HOME}/.config/opencode/opencode.json`] as string) as {
      mcp: { local: { enabled: boolean } }
    }
    expect(opencodeAfter.mcp.local.enabled).toBe(false)
    expect(
      harnessGroup(openScan, "opencode").servers.find((s) => s.serverName === "local")?.enabled
    ).toBe(false)

    await manager.setNativeEnabled("cline", "docs", false)
    const clineAfter = JSON.parse(
      files[`${HOME}/.cline/data/settings/cline_mcp_settings.json`] as string
    ) as { mcpServers: { docs: { disabled: boolean } } }
    expect(clineAfter.mcpServers.docs.disabled).toBe(true)

    await manager.setNativeEnabled("cline", "docs", true)
    expect(
      (
        JSON.parse(files[`${HOME}/.cline/data/settings/cline_mcp_settings.json`] as string) as {
          mcpServers: { docs: { disabled: boolean } }
        }
      ).mcpServers.docs.disabled
    ).toBe(false)
  })

  it("rejects operations on unknown, unwritable, or flagless harnesses", async () => {
    const files: Record<string, string | Error> = {
      [`${HOME}/.config/goose/config.yaml`]: "extensions:\n  docs:\n    cmd: uvx\n",
      [`${HOME}/.claude.json`]: CLAUDE_FIXTURE
    }
    const { manager } = await testManager(files)
    await expect(manager.removeServer("not-a-harness", "docs")).rejects.toMatchObject({
      code: "notFound"
    })
    // amp has no nativeMcp metadata at all.
    await expect(manager.removeServer("amp", "docs")).rejects.toMatchObject({
      code: "notFound"
    })
    // goose is scan-only (writable: false).
    await expect(manager.removeServer("goose", "docs")).rejects.toMatchObject({
      code: "unsupported"
    })
    // claude-code has no native enable flag.
    await expect(manager.setNativeEnabled("claude-code", "docs", false)).rejects.toMatchObject({
      code: "unsupported"
    })
    // Missing file and missing entries.
    await expect(manager.removeServer("gemini", "docs")).rejects.toMatchObject({
      code: "notFound"
    })
    await expect(manager.removeServer("claude-code", "ghost")).rejects.toMatchObject({
      code: "notFound"
    })
    await expect(manager.setNativeEnabled("opencode", "ghost", true)).rejects.toMatchObject({
      code: "notFound"
    })
  })
})
