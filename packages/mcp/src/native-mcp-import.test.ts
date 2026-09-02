import { afterEach, describe, expect, it } from "vitest"
import { cleanupNativeMcpTests, run, HOME, testManager } from "./native-mcp-test-support.js"

afterEach(cleanupNativeMcpTests)

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
