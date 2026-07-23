import type { CreateMcpServerRequest, McpAuthDetection } from "@codevisor/api"
import { makeAgentRuntime } from "@codevisor/agent-runtime"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { mkdtempSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import {
  type ImportTargetMcpManager,
  makeNativeMcpManager,
  type NativeMcpManager
} from "./native-mcp-manager.js"
import type { NativeConfigFileSystem } from "./native-config-files.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: CodevisorDatabaseService[] = []

afterEach(async () => {
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

const HOME = "/home/u"

/// In-memory filesystem: reads serve from the record, atomic writes mutate
/// it — so write-pipeline tests can assert on resulting file contents.
const fakeFs = (files: Record<string, string | Error>): NativeConfigFileSystem => ({
  readFile: async (path) => {
    const value = files[path]
    if (value instanceof Error) throw value
    return value
  },
  writeFileAtomic: async (path, content) => {
    files[path] = content
  }
})

interface ImportFakes {
  readonly createRequests: Array<CreateMcpServerRequest>
  readonly detectedUrls: Array<string>
}

/// Fake managed-MCP store: `create` persists through the real db (so
/// post-import scans see `alreadyManaged`), `detectAuth` is scripted.
const fakeMcp = (
  db: CodevisorDatabaseService,
  behavior: {
    readonly detectAuth?: (url: string) => Promise<McpAuthDetection>
    readonly create?: (request: CreateMcpServerRequest) => Promise<never>
  } = {}
): { readonly fakes: ImportFakes; readonly mcp: ImportTargetMcpManager } => {
  const createRequests: Array<CreateMcpServerRequest> = []
  const detectedUrls: Array<string> = []
  return {
    fakes: { createRequests, detectedUrls },
    mcp: {
      create: async (request) => {
        if (behavior.create !== undefined) return behavior.create(request)
        createRequests.push(request)
        return run(
          db.saveMcpServer({
            args: request.args === undefined ? [] : [...request.args],
            authType: request.authType ?? "none",
            ...(request.command === undefined ? {} : { command: request.command }),
            connectionState: "disconnected",
            enabled: true,
            name: request.name,
            toolCount: 0,
            transport: request.transport,
            ...(request.url === undefined ? {} : { url: request.url })
          })
        )
      },
      detectAuth: async (url) => {
        detectedUrls.push(url)
        if (behavior.detectAuth !== undefined) return behavior.detectAuth(url)
        return { authType: "none", detail: "No authorization challenge detected" }
      }
    }
  }
}

const testManager = async (
  files: Record<string, string | Error>,
  env: Record<string, string | undefined> = {},
  behavior: Parameters<typeof fakeMcp>[1] = {}
): Promise<{
  db: CodevisorDatabaseService
  fakes: ImportFakes
  manager: NativeMcpManager
}> => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-native-mcp-"))
  directories.push(directory)
  const db = await run(
    makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
  )
  databases.push(db)
  const { fakes, mcp } = fakeMcp(db, behavior)
  const manager = makeNativeMcpManager({
    agents: makeAgentRuntime({}),
    dataDir: directory,
    db,
    env,
    fs: fakeFs(files),
    homedir: HOME,
    mcp
  })
  return { db, fakes, manager }
}

const harnessGroup = (scan: Awaited<ReturnType<NativeMcpManager["scan"]>>, id: string) => {
  const group = scan.harnesses.find((harness) => harness.harnessId === id)
  if (group === undefined) throw new Error(`missing harness group ${id}`)
  return group
}

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
        mcpServers: { node_repl: { command: "user-node-repl" } }
      }),
      [`${HOME}/.codex/config.toml`]: `[mcp_servers.node_repl]
command = "native-node-repl"

[mcp_servers.computer-use]
command = "native-computer-use"

[mcp_servers.docs]
command = "docs-mcp"
`
    })

    const scan = await manager.scan()
    expect(harnessGroup(scan, "codex").servers.map((server) => server.serverName)).toEqual(["docs"])
    expect(harnessGroup(scan, "claude-code").servers.map((server) => server.serverName)).toEqual([
      "node_repl"
    ])
    expect(scan.candidates.map((candidate) => candidate.identity).sort()).toEqual([
      "docs-mcp",
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

describe("importServers", () => {
  const CLAUDE_CONFIG = JSON.stringify({
    mcpServers: {
      docs: { args: ["-y", "docs-mcp"], command: "npx", env: { TOKEN: "secret" } },
      linear: { type: "http", url: "https://mcp.linear.app/mcp" }
    }
  })

  it("imports a stdio candidate with its secrets and flips it to alreadyManaged", async () => {
    const { fakes, manager } = await testManager({ [`${HOME}/.claude.json`]: CLAUDE_CONFIG })
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes).toEqual([
      {
        identity: "docs-mcp",
        serverId: expect.any(String),
        serverName: "docs",
        status: "imported",
        warnings: []
      }
    ])
    expect(fakes.createRequests).toEqual([
      {
        args: ["-y", "docs-mcp"],
        authType: "none",
        command: "npx",
        enabled: true,
        env: { TOKEN: "secret" },
        name: "docs",
        transport: "stdio"
      }
    ])
    // stdio imports never probe authorization.
    expect(fakes.detectedUrls).toEqual([])
    const candidate = result.scan.candidates.find((entry) => entry.identity === "docs-mcp")
    expect(candidate?.alreadyManaged).toBe(true)
  })

  it("skips candidates that are already managed", async () => {
    const { db, manager } = await testManager({ [`${HOME}/.claude.json`]: CLAUDE_CONFIG })
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
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]).toMatchObject({
      detail: "Already managed by Codevisor",
      status: "skipped"
    })
  })

  it("fails unknown identities without aborting the batch", async () => {
    const { manager } = await testManager({ [`${HOME}/.claude.json`]: CLAUDE_CONFIG })
    const result = await manager.importServers({ identities: ["ghost-mcp", "docs-mcp"] })
    expect(result.outcomes[0]).toMatchObject({ identity: "ghost-mcp", status: "failed" })
    expect(result.outcomes[1]).toMatchObject({ identity: "docs-mcp", status: "imported" })
  })

  it("probes bare remote servers and adopts detected OAuth", async () => {
    const { fakes, manager } = await testManager(
      { [`${HOME}/.claude.json`]: CLAUDE_CONFIG },
      {},
      {
        detectAuth: async () => ({ authType: "oauth", detail: "OAuth required" })
      }
    )
    const result = await manager.importServers({
      identities: ["https://mcp.linear.app/mcp"]
    })
    expect(result.outcomes[0]).toMatchObject({ status: "imported" })
    expect(fakes.detectedUrls).toEqual(["https://mcp.linear.app/mcp"])
    expect(fakes.createRequests[0]).toMatchObject({
      authType: "oauth",
      transport: "http",
      url: "https://mcp.linear.app/mcp"
    })
  })

  it("adopts detected bearer auth and keeps none for unprotected servers", async () => {
    const bearer = await testManager(
      { [`${HOME}/.claude.json`]: CLAUDE_CONFIG },
      {},
      {
        detectAuth: async () => ({ authType: "bearer", detail: "Token required" })
      }
    )
    const bearerResult = await bearer.manager.importServers({
      identities: ["https://mcp.linear.app/mcp"]
    })
    expect(bearerResult.outcomes[0]?.status).toBe("imported")
    expect(bearer.fakes.createRequests[0]).toMatchObject({ authType: "bearer" })

    const open = await testManager({ [`${HOME}/.claude.json`]: CLAUDE_CONFIG })
    await open.manager.importServers({ identities: ["https://mcp.linear.app/mcp"] })
    expect(open.fakes.detectedUrls).toEqual(["https://mcp.linear.app/mcp"])
    expect(open.fakes.createRequests[0]).toMatchObject({ authType: "none" })
  })

  it("degrades to no auth with a warning when the probe fails", async () => {
    const { fakes, manager } = await testManager(
      { [`${HOME}/.claude.json`]: CLAUDE_CONFIG },
      {},
      {
        detectAuth: async () => {
          throw new Error("network unreachable")
        }
      }
    )
    const result = await manager.importServers({
      identities: ["https://mcp.linear.app/mcp"]
    })
    expect(result.outcomes[0]?.status).toBe("imported")
    expect(result.outcomes[0]?.warnings[0]).toContain("Couldn't probe")
    expect(fakes.createRequests[0]).toMatchObject({ authType: "none" })
  })

  it("skips the probe when the native entry already carries headers", async () => {
    const { fakes, manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          linear: {
            headers: { Authorization: "Bearer abc" },
            type: "http",
            url: "https://mcp.linear.app/mcp"
          }
        }
      })
    })
    await manager.importServers({ identities: ["https://mcp.linear.app/mcp"] })
    expect(fakes.detectedUrls).toEqual([])
    expect(fakes.createRequests[0]).toMatchObject({
      authType: "none",
      headers: { Authorization: "Bearer abc" }
    })
  })

  it("warns about shell-variable placeholders imported verbatim", async () => {
    const { manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: {
          docs: { command: "docs-mcp", env: { TOKEN: "${GITHUB_TOKEN}" } }
        }
      })
    })
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]?.status).toBe("imported")
    expect(result.outcomes[0]?.warnings[0]).toContain("TOKEN references a shell variable")
  })

  it("suffixes the harness name on managed-name collisions", async () => {
    const { db, fakes, manager } = await testManager({
      [`${HOME}/.claude.json`]: CLAUDE_CONFIG
    })
    // Same *name*, different identity — the import must rename, not skip.
    await run(
      db.saveMcpServer({
        authType: "none",
        connectionState: "disconnected",
        enabled: true,
        name: "docs",
        toolCount: 0,
        transport: "http",
        url: "https://other.example.com"
      })
    )
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]).toMatchObject({
      serverName: "docs (Claude Code)",
      status: "imported"
    })
    expect(fakes.createRequests[0]?.name).toBe("docs (Claude Code)")
  })

  it("fails when both the plain and suffixed names are taken", async () => {
    const { db, manager } = await testManager({ [`${HOME}/.claude.json`]: CLAUDE_CONFIG })
    for (const name of ["docs", "docs (Claude Code)"]) {
      await run(
        db.saveMcpServer({
          authType: "none",
          connectionState: "disconnected",
          enabled: true,
          name,
          toolCount: 0,
          transport: "http",
          url: `https://${name.length}.example.com`
        })
      )
    }
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]).toMatchObject({ status: "failed" })
    expect(result.outcomes[0]?.detail).toContain("already exists")
  })

  it("prefers the global registration over a project one for the same identity", async () => {
    const { db, fakes, manager } = await testManager({
      [`${HOME}/.claude.json`]: JSON.stringify({
        mcpServers: { docs: { args: ["-y", "docs-mcp"], command: "npx", env: { FROM: "global" } } }
      }),
      "/proj/app/.mcp.json": JSON.stringify({
        mcpServers: { docs: { args: ["-y", "docs-mcp"], command: "npx" } }
      })
    })
    await run(db.createProject({ folderPath: "/proj/app", name: "App" }))
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]?.status).toBe("imported")
    expect(fakes.createRequests[0]?.env).toEqual({ FROM: "global" })
  })

  it("imports project-only candidates", async () => {
    const { db, manager } = await testManager({
      "/proj/app/.mcp.json": JSON.stringify({
        mcpServers: { docs: { args: ["-y", "docs-mcp"], command: "npx" } }
      })
    })
    await run(db.createProject({ folderPath: "/proj/app", name: "App" }))
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]?.status).toBe("imported")
  })

  it("reports create failures per item", async () => {
    const { manager } = await testManager(
      { [`${HOME}/.claude.json`]: CLAUDE_CONFIG },
      {},
      {
        create: async () => {
          throw new Error("disk full")
        }
      }
    )
    const result = await manager.importServers({ identities: ["docs-mcp"] })
    expect(result.outcomes[0]).toMatchObject({ detail: "disk full", status: "failed" })
  })
})

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
