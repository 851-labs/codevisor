import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("persists MCP server configuration and encrypted credential payloads", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const created = await run(
      db.saveMcpServer({
        name: "Linear",
        transport: "http",
        url: "https://example.test/mcp",
        enabled: true,
        authType: "oauth",
        oauthScope: "read write",
        connectionState: "needsAuthorization",
        toolCount: 0,
        secretCipher: "opaque-ciphertext"
      })
    )
    expect(created).toMatchObject({
      authType: "oauth",
      canEdit: true,
      canRemove: true,
      enabled: true,
      kind: "managed",
      name: "Linear",
      secretCipher: "opaque-ciphertext",
      transport: "http"
    })

    const updated = await run(
      db.saveMcpServer({
        id: created.id,
        name: created.name,
        transport: created.transport,
        ...(created.url === undefined ? {} : { url: created.url }),
        ...(created.command === undefined ? {} : { command: created.command }),
        args: created.args,
        enabled: created.enabled,
        authType: created.authType,
        ...(created.oauthScope === undefined ? {} : { oauthScope: created.oauthScope }),
        connectionState: "connected",
        toolCount: 18,
        ...(created.secretCipher === undefined ? {} : { secretCipher: created.secretCipher })
      })
    )
    expect(updated.connectionState).toBe("connected")
    expect((await run(db.listMcpServers))[0]?.toolCount).toBe(18)
    expect(await run(db.getMcpServer(created.id))).toMatchObject({
      id: created.id,
      name: "Linear",
      toolCount: 18
    })
    expect(await run(db.getMcpServer("missing-mcp"))).toBeUndefined()

    const local = await run(
      db.saveMcpServer({
        args: ["@playwright/mcp@latest"],
        authType: "none",
        command: "npx",
        connectionState: "error",
        detail: "Not installed",
        enabled: false,
        name: "Playwright",
        toolCount: 0,
        transport: "stdio"
      })
    )
    expect(local).toMatchObject({
      args: ["@playwright/mcp@latest"],
      command: "npx",
      detail: "Not installed",
      enabled: false
    })
    expect(local.url).toBeUndefined()
    expect(local.oauthScope).toBeUndefined()
    expect(local.secretCipher).toBeUndefined()
    expect((await run(db.resolveMcpServers())).map((server) => server.id)).toEqual([
      created.id,
      local.id
    ])

    const project = await run(db.createProject({ folderPath: "/tmp/mcp-scope" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Scoped" })
    )
    await run(db.setProjectMcpEnabled(project.id, created.id, false))
    expect((await run(db.resolveMcpServers(project.id)))[0]?.enabled).toBe(false)
    await run(db.setProjectMcpEnabled(project.id, created.id, true))
    await run(db.setSessionMcpEnabled(session.id, created.id, false))
    expect((await run(db.resolveMcpServers(project.id, session.id)))[0]?.enabled).toBe(false)
    await run(db.setSessionMcpEnabled(session.id, created.id, true))
    expect((await run(db.resolveMcpServers(project.id, session.id)))[0]?.enabled).toBe(true)

    await run(db.deleteMcpServer(created.id))
    await run(db.deleteMcpServer(local.id))
    expect(await run(db.listMcpServers)).toEqual([])
    await Effect.runPromise(db.close)
  })
})
