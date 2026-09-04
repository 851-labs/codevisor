import { makeAgentRuntime } from "@codevisor/agent-runtime"
import { makeDatabase } from "@codevisor/db"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeNativeMcpManager } from "./native-mcp-manager.js"
import type { NativeConfigFileSystem } from "./native-config-files.js"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupNativeMcpTests,
  run,
  directories,
  databases,
  HOME,
  fakeMcp,
  testManager,
  harnessGroup
} from "./native-mcp-test-support.js"

afterEach(cleanupNativeMcpTests)

describe("makeNativeMcpManager", () => {
  it("constructs with default filesystem, home, and env seams", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-native-mcp-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const { mcp } = fakeMcp(db)
    expect(
      makeNativeMcpManager({ agents: makeAgentRuntime({}), dataDir: directory, db, mcp })
    ).toBeDefined()
  })

  it("reports every cataloged harness with nativeMcp metadata, absent files as exists=false", async () => {
    const { manager } = await testManager({})
    const scan = await manager.scan()
    const ids = scan.harnesses.map((harness) => harness.harnessId)
    expect(ids).toContain("claude-code")
    expect(ids).toContain("codex")
    expect(ids).toContain("opencode")
    expect(ids).toContain("goose")
    expect(ids).not.toContain("amp")
    for (const harness of scan.harnesses) {
      expect(harness.exists).toBe(false)
      expect(harness.servers).toEqual([])
      expect(harness.error).toBeUndefined()
    }
    expect(scan.candidates).toEqual([])
  })

  it("scans claude-code global servers and exposes secret names only", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          docs: { args: ["-y", "docs-mcp"], command: "npx", env: { TOKEN: "secret" } },
          linear: {
            headers: { Authorization: "Bearer abc" },
            type: "http",
            url: "https://mcp.linear.app/mcp"
          }
        },
        otherState: { untouched: true }
      })
    })
    const scan = await manager.scan()
    const claude = harnessGroup(scan, "claude-code")
    expect(claude.exists).toBe(true)
    expect(claude.servers).toHaveLength(2)
    const docs = claude.servers.find((server) => server.serverName === "docs")
    expect(docs).toMatchObject({
      alreadyManaged: false,
      command: "npx",
      envNames: ["TOKEN"],
      identity: "docs-mcp",
      scope: "global",
      supportsDisable: false,
      supportsRemove: true,
      transport: "stdio"
    })
    const linear = claude.servers.find((server) => server.serverName === "linear")
    expect(linear !== undefined && "enabled" in linear).toBe(false)
    expect(linear).toMatchObject({
      headerNames: ["Authorization"],
      identity: "https://mcp.linear.app/mcp",
      transport: "http",
      url: "https://mcp.linear.app/mcp"
    })
  })

  it("coalesces the same server across harnesses into one candidate", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: { docs: { args: ["-y", "docs-mcp"], command: "npx" } }
      }),
      [`${HOME}/.codex/config.toml`]: `[mcp_servers.docs]
command = "npx"
args = ["-y", "docs-mcp"]
`
    })
    const scan = await manager.scan()
    expect(scan.candidates).toHaveLength(1)
    expect(scan.candidates[0]).toMatchObject({
      foundIn: ["claude-code", "codex"],
      identity: "docs-mcp",
      name: "docs"
    })
  })

  it("dedupes foundIn within a single harness", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          "docs-a": { url: "https://mcp.example.com/" },
          "docs-b": { url: "https://MCP.example.com" }
        }
      })
    })
    const scan = await manager.scan()
    expect(scan.candidates).toHaveLength(1)
    expect(scan.candidates[0]?.foundIn).toEqual(["claude-code"])
  })

  it("marks servers matching Codevisor-managed entries as alreadyManaged", async () => {
    const { db, manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          docs: { args: ["-y", "docs-mcp"], command: "npx" },
          linear: { url: "https://mcp.linear.app/mcp/" }
        }
      })
    })
    await run(
      db.saveMcpServer({
        authType: "oauth",
        connectionState: "disconnected",
        enabled: true,
        name: "Linear",
        toolCount: 0,
        transport: "http",
        url: "https://mcp.linear.app/mcp"
      })
    )
    await run(
      db.saveMcpServer({
        args: ["-y", "docs-mcp"],
        authType: "none",
        command: "npx",
        connectionState: "disconnected",
        enabled: true,
        name: "Docs",
        toolCount: 0,
        transport: "stdio"
      })
    )
    const scan = await manager.scan()
    const claude = harnessGroup(scan, "claude-code")
    expect(claude.servers.find((server) => server.serverName === "linear")?.alreadyManaged).toBe(
      true
    )
    expect(claude.servers.find((server) => server.serverName === "docs")?.alreadyManaged).toBe(true)
    const linearCandidate = scan.candidates.find((candidate) => candidate.name === "linear")
    expect(linearCandidate?.alreadyManaged).toBe(true)
  })

  it("ignores managed servers without a derivable identity", async () => {
    const { db, manager } = await testManager({})
    await run(
      db.saveMcpServer({
        authType: "none",
        connectionState: "disconnected",
        enabled: true,
        name: "Broken",
        toolCount: 0,
        transport: "stdio"
      })
    )
    const scan = await manager.scan()
    expect(scan.candidates).toEqual([])
  })

  it("honors opencode's enabled flag and disable/remove support", async () => {
    const { manager } = await testManager({
      [`${HOME}/.config/opencode/opencode.json`]: JSON.stringify({
        mcp: {
          local: { command: ["bun", "x", "my-mcp"], enabled: false, type: "local" },
          remote: { type: "remote", url: "https://mcp.example.com" }
        }
      })
    })
    const scan = await manager.scan()
    const opencode = harnessGroup(scan, "opencode")
    expect(opencode.servers.find((server) => server.serverName === "local")).toMatchObject({
      enabled: false,
      supportsDisable: true,
      supportsRemove: true
    })
    expect(opencode.servers.find((server) => server.serverName === "remote")).toMatchObject({
      enabled: true,
      transport: "http"
    })
  })

  it("honors XDG_CONFIG_HOME for opencode", async () => {
    const { manager } = await testManager(
      {
        "/xdg/opencode/opencode.json": JSON.stringify({
          mcp: { remote: { type: "remote", url: "https://mcp.example.com" } }
        })
      },
      { XDG_CONFIG_HOME: "/xdg" }
    )
    const scan = await manager.scan()
    const opencode = harnessGroup(scan, "opencode")
    expect(opencode.configPath).toBe("/xdg/opencode/opencode.json")
    expect(opencode.servers).toHaveLength(1)
  })

  it("honors CODEX_HOME for codex", async () => {
    const { manager } = await testManager(
      {
        "/codex-home/config.toml": `[mcp_servers.docs]
command = "docs-mcp"
`
      },
      { CODEX_HOME: "/codex-home" }
    )
    const scan = await manager.scan()
    const codex = harnessGroup(scan, "codex")
    expect(codex.configPath).toBe("/codex-home/config.toml")
    expect(codex.servers).toHaveLength(1)
  })

  it("hides Codex native automation transports from MCP settings discovery", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          node_repl: { command: "user-node-repl" },
          cua_repl: { command: "user-cua-repl" }
        }
      }),
      [`${HOME}/.codex/config.toml`]: `[mcp_servers.node_repl]
command = "native-node-repl"

[mcp_servers.computer-use]
command = "native-computer-use"

[mcp_servers.cua_repl]
command = "native-cua-repl"

[mcp_servers.docs]
command = "docs-mcp"
`
    })

    const scan = await manager.scan()
    expect(harnessGroup(scan, "codex").servers.map((server) => server.serverName)).toEqual(["docs"])
    expect(harnessGroup(scan, "claude-code").servers.map((server) => server.serverName)).toEqual([
      "node_repl",
      "cua_repl"
    ])
    expect(scan.candidates.map((candidate) => candidate.identity).sort()).toEqual([
      "docs-mcp",
      "user-cua-repl",
      "user-node-repl"
    ])
  })

  it("reads goose YAML as scan-only (no disable/remove support)", async () => {
    const { manager } = await testManager({
      [`${HOME}/.config/goose/config.yaml`]: `extensions:
  docs:
    cmd: uvx
    args: [docs-mcp]
    envs:
      KEY: value
    enabled: true
    type: stdio
`
    })
    const scan = await manager.scan()
    const goose = harnessGroup(scan, "goose")
    expect(goose.servers[0]).toMatchObject({
      command: "uvx",
      enabled: true,
      envNames: ["KEY"],
      supportsDisable: false,
      supportsRemove: false
    })
  })

  it("surfaces per-harness parse failures without failing the scan", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: "{ definitely not json",
      [`${HOME}/.gemini/settings.json`]: JSON.stringify({
        mcpServers: { docs: { command: "docs-mcp" } }
      })
    })
    const scan = await manager.scan()
    const claude = harnessGroup(scan, "claude-code")
    expect(claude.exists).toBe(true)
    expect(claude.error).toContain("invalid JSON")
    expect(claude.servers).toEqual([])
    expect(harnessGroup(scan, "gemini").servers).toHaveLength(1)
  })

  it("stringifies non-Error read failures", async () => {
    const fs: NativeConfigFileSystem = {
      readFile: async (path) => {
        if (path === `${HOME}/.claude.json`) {
          throw "permission denied"
        }
        return undefined
      },
      writeFileAtomic: async () => {}
    }
    const directory = mkdtempSync(join(tmpdir(), "codevisor-native-mcp-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const manager = makeNativeMcpManager({
      agents: makeAgentRuntime({}),
      dataDir: directory,
      db,
      env: {},
      fs,
      homedir: HOME,
      mcp: fakeMcp(db).mcp
    })
    const scan = await manager.scan()
    expect(harnessGroup(scan, "claude-code").error).toBe("permission denied")
  })

  it("tolerates a servers key that is not an object", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({ mcpServers: ["not", "a", "map"] })
    })
    const scan = await manager.scan()
    const claude = harnessGroup(scan, "claude-code")
    expect(claude.exists).toBe(true)
    expect(claude.servers).toEqual([])
  })

  it("skips unrecognizable entries instead of failing", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: { bad: { type: "http" }, good: { command: "docs-mcp" }, worse: 4 }
      })
    })
    const scan = await manager.scan()
    expect(harnessGroup(scan, "claude-code").servers.map((server) => server.serverName)).toEqual([
      "good"
    ])
  })

  it("reads project .mcp.json files as read-only project scope", async () => {
    const { db, manager } = await testManager({
      "/proj/app/.mcp.json": JSON.stringify({
        mcpServers: { docs: { args: ["-y", "docs-mcp"], command: "npx" } }
      })
    })
    await run(db.createProject({ folderPath: "/proj/app", name: "App" }))
    const scan = await manager.scan()
    const claude = harnessGroup(scan, "claude-code")
    expect(claude.exists).toBe(false)
    expect(claude.servers).toHaveLength(1)
    expect(claude.servers[0]).toMatchObject({
      configPath: "/proj/app/.mcp.json",
      scope: "project",
      supportsDisable: false,
      supportsRemove: false
    })
    expect(scan.candidates.map((candidate) => candidate.identity)).toEqual(["docs-mcp"])
  })

  it("never lets a malformed project file poison the scan", async () => {
    const { db, manager } = await testManager({
      "/proj/app/.mcp.json": "{ broken",
      "/proj/lib/.mcp.json": JSON.stringify({ mcpServers: { docs: { command: "docs-mcp" } } })
    })
    await run(db.createProject({ folderPath: "/proj/app", name: "App" }))
    await run(db.createProject({ folderPath: "/proj/lib", name: "Lib" }))
    const scan = await manager.scan()
    const claude = harnessGroup(scan, "claude-code")
    expect(claude.error).toBeUndefined()
    expect(claude.servers.map((server) => server.configPath)).toEqual(["/proj/lib/.mcp.json"])
  })

  it("sorts candidates by name", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          zeta: { url: "https://zeta.example.com" },
          alpha: { url: "https://alpha.example.com" }
        }
      })
    })
    const scan = await manager.scan()
    expect(scan.candidates.map((candidate) => candidate.name)).toEqual(["alpha", "zeta"])
  })
})
