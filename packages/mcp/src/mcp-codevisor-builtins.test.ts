import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import { createServer } from "node:http"
import { afterEach, describe, expect, it } from "vitest"
import {
  unavailableBrowserProvider,
  unavailableComputerProvider
} from "./mcp-automation-builtins.js"
import { makeMcpManager } from "./mcp-manager.js"
import {
  cleanupMcpManagerTests,
  listen,
  managers,
  run,
  testManager
} from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

// These cases exercise Codevisor itself; desktop/browser state is irrelevant.
const providers = {
  makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test"),
  makeComputerProvider: () => unavailableComputerProvider("Not used in this test")
}

describe("Codevisor built-in tools", () => {
  it("lists its tools in settings and preserves a disabled provider across restarts", async () => {
    const { db, manager, directory } = await testManager(undefined, providers)
    const tools = await manager.tools("codevisor")
    expect(tools).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ serverId: "codevisor", name: "sessions.create" })
      ])
    )
    expect((await manager.list()).find((server) => server.id === "codevisor")).toMatchObject({
      name: "Codevisor",
      kind: "codevisor",
      enabled: true,
      connectionState: "connected",
      canEdit: false,
      canRemove: false,
      toolCount: tools.length
    })
    const catalog = (await manager.tools(undefined)).filter((tool) => tool.serverId === "codevisor")
    expect(catalog).toHaveLength(tools.length)
    expect(new Set(catalog.map((tool) => tool.name)).size).toBe(tools.length)

    await manager.update("codevisor", { enabled: false })
    await manager.close()
    const restarted = makeMcpManager({ db, dataDir: directory, ...providers })
    managers.push(restarted)
    expect((await restarted.list()).find((server) => server.id === "codevisor")).toMatchObject({
      enabled: false,
      connectionState: "disconnected",
      toolCount: tools.length
    })
    expect((await restarted.tools(undefined)).some((tool) => tool.serverId === "codevisor")).toBe(
      false
    )
    // Settings can still explain what this disabled provider offers.
    expect(await restarted.tools("codevisor")).toEqual(tools)
    expect(await restarted.update("codevisor", { enabled: true })).toMatchObject({
      enabled: true,
      connectionState: "connected"
    })
  })

  it.each(["global", "machine", "project", "session"] as const)(
    "enforces a %s disable in discovery, descriptions, and direct calls on a live gateway",
    async (scope) => {
      const { db, manager } = await testManager(undefined, providers)
      const base = await listen(createServer(manager.handleGatewayRequest))
      manager.setBaseUrl(base)
      const project = await run(db.createProject({ folderPath: "/tmp/codevisor-toggle-test" }))
      const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
      const gateway = await manager.issueGateway(session.id, project.id)
      const client = new Client({ name: "codevisor-toggle-test", version: "1" })
      try {
        await client.connect(
          new StreamableHTTPClientTransport(new URL(gateway.url), {
            requestInit: { headers: { authorization: `Bearer ${gateway.bearerToken}` } }
          }) as unknown as Transport
        )
        const execute = (code: string) => client.callTool({ name: "execute", arguments: { code } })
        const search = () => execute('async () => tools.search({ query: "sessions.create" })')
        const describeTool = () =>
          execute('async () => tools.describe.tool({ path: "codevisor.sessions.create" })')
        const call = () => execute('async () => tools["codevisor.context.current"]({})')
        const inventory = async () => (await client.listTools()).tools[0]?.description
        const setEnabled = async (enabled: boolean) => {
          const changed = Promise.withResolvers<void>()
          client.setNotificationHandler(ToolListChangedNotificationSchema, () => changed.resolve())
          switch (scope) {
            case "global":
              await manager.update("codevisor", { enabled })
              break
            case "machine":
              await manager.setLocalSuppression(new Set(enabled ? [] : ["Codevisor"]))
              break
            case "project":
              await manager.setProjectEnabled(project.id, "codevisor", enabled)
              break
            case "session":
              await manager.setSessionEnabled(session.id, "codevisor", enabled, project.id)
              break
          }
          await changed.promise
        }

        expect(await inventory()).toContain("\n- Codevisor")
        expect(JSON.stringify((await search()).content)).toContain("codevisor.sessions.create")
        expect((await describeTool()).isError).not.toBe(true)
        expect((await call()).isError).not.toBe(true)

        await setEnabled(false)
        expect(await inventory()).not.toContain("\n- Codevisor")
        expect(JSON.stringify((await search()).content)).not.toContain("codevisor.sessions.create")
        expect((await describeTool()).isError).toBe(true)
        expect(await call()).toMatchObject({
          isError: true,
          content: [
            expect.objectContaining({ text: expect.stringContaining("disabled for this session") })
          ]
        })

        await setEnabled(true)
        expect(await inventory()).toContain("\n- Codevisor")
        expect(JSON.stringify((await search()).content)).toContain("codevisor.sessions.create")
        expect((await describeTool()).isError).not.toBe(true)
        expect((await call()).isError).not.toBe(true)
      } finally {
        await client.close()
      }
    }
  )
})
