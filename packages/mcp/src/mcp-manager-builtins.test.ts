import { makeDatabase } from "@codevisor/db"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeMcpManager } from "./mcp-manager.js"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  cleanupMcpManagerTests,
  run,
  directories,
  databases,
  managers,
  testManager,
  workingUpstream
} from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

describe("MCP manager built-in providers and suppression", () => {
  it("keeps built-in automation providers immutable but disableable", async () => {
    const { manager } = await testManager()
    await expect(manager.remove("browser")).rejects.toThrow("cannot be removed")
    await expect(manager.update("computer", { name: "Renamed" })).rejects.toThrow(
      "managed by Codevisor"
    )
    const disabled = await manager.update("computer", { enabled: false })
    expect(disabled).toMatchObject({
      canEdit: false,
      canRemove: false,
      enabled: false,
      id: "computer",
      kind: "computerUse"
    })
    expect((await manager.resolved()).find((server) => server.id === "computer")?.enabled).toBe(
      false
    )
  })

  it("synchronizes proper managed skills with built-in provider state", async () => {
    const synchronized: Array<ReadonlyArray<{ directoryName: string; enabled: boolean }>> = []
    const { manager } = await testManager(async (skills) => {
      synchronized.push(skills.map(({ directoryName, enabled }) => ({ directoryName, enabled })))
    })
    await manager.list()
    expect(synchronized.at(-1)).toEqual([
      { directoryName: "browser-use", enabled: true },
      { directoryName: "computer-use", enabled: true }
    ])

    await manager.update("computer", { enabled: false })
    expect(synchronized.at(-1)).toEqual([
      { directoryName: "browser-use", enabled: true },
      { directoryName: "computer-use", enabled: false }
    ])
  })

  it("keeps a Browser Use provider startup failure scoped to Browser Use", async () => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-browser-provider-failure-"))
    directories.push(directory)
    const db = await run(
      makeDatabase({ filename: join(directory, "codevisor.sqlite"), serverId: "test" })
    )
    databases.push(db)
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const manager = makeMcpManager({
      db,
      dataDir: directory,
      makeBrowserProvider: () => {
        throw new Error("extension archive is unreadable")
      }
    })
    managers.push(manager)

    await expect(manager.list()).resolves.toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "browser",
          connectionState: "needsSetup",
          detail: "extension archive is unreadable"
        }),
        expect.objectContaining({ id: "computer" })
      ])
    )
    await expect(manager.browserConfiguration()).resolves.toMatchObject({
      chromeConnected: false,
      managedAvailable: false
    })
    expect(errors).toHaveBeenCalledWith("Browser Use unavailable: extension archive is unreadable")
  })

  it("contains managed-skill synchronization failures", async () => {
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const { manager } = await testManager(async () => {
      throw new Error("managed skill directory is read-only")
    })

    await expect(manager.list()).resolves.toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id: "browser" }),
        expect.objectContaining({ id: "computer" })
      ])
    )
    expect(errors).toHaveBeenCalledWith(
      "Built-in MCP initialization failed: managed skill directory is read-only"
    )
    await expect(manager.update("computer", { enabled: false })).resolves.toMatchObject({
      enabled: false,
      id: "computer"
    })
    expect(errors).toHaveBeenCalledWith(
      "Managed automation skill synchronization failed: managed skill directory is read-only"
    )
  })

  it("drops suppressed servers from resolution, refuses connection, and disconnects", async () => {
    const upstream = await workingUpstream()
    const { manager } = await testManager()
    const created = await manager.create({
      authType: "none",
      enabled: true,
      name: "Suppressible",
      transport: "http",
      url: upstream.url
    })
    expect(created.connectionState).toBe("connected")

    await manager.setLocalSuppression(new Set(["Suppressible"]))
    // Sessions never see it, while the fleet definition stays enabled.
    expect((await manager.resolved()).some((server) => server.name === "Suppressible")).toBe(false)
    const listed = (await manager.list()).find((server) => server.name === "Suppressible")
    expect(listed?.enabled).toBe(true)
    expect(listed?.connectionState).toBe("disconnected")
    await expect(manager.connect(created.id)).rejects.toThrow("disabled on this machine")
    // Idempotent re-application with no live connection left to close.
    await manager.setLocalSuppression(new Set(["Suppressible"]))

    // Lifting the suppression restores resolution and connectability.
    await manager.setLocalSuppression(new Set())
    expect((await manager.resolved()).some((server) => server.name === "Suppressible")).toBe(true)
    expect((await manager.connect(created.id)).connectionState).toBe("connected")
  })

  it("hides a suppressed built-in provider's tools from the catalog", async () => {
    // Built-ins never pass through connectUpstream, so without an explicit
    // catalog check a machine-disabled Computer Use would keep advertising
    // its tools to every session.
    const { manager } = await testManager()
    const computer = (await manager.list()).find((server) => server.kind === "computerUse")
    if (computer === undefined) throw new Error("computer use provider missing")

    const before = await manager.tools(undefined)
    await manager.setLocalSuppression(new Set([computer.name]))
    const suppressed = await manager.tools(undefined)
    expect(suppressed.some((tool) => tool.serverId === computer.id)).toBe(false)

    await manager.setLocalSuppression(new Set())
    expect((await manager.tools(undefined)).length).toBe(before.length)
  })
})
