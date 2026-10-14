import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import {
  MCP_OVERLAYS_NAMESPACE,
  mcpOverlayDisableKey,
  mcpReadiness,
  publishMcpReadiness,
  readMcpOverlays,
  MCP_READINESS_NAMESPACE,
  type McpOverlays
} from "./mcp-fleet.js"

const at = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })

const none: McpOverlays = { disabledHere: new Set() }

describe("mcp overlays", () => {
  it("reads only this machine's disables, ignoring noise", async () => {
    const { services } = await makeServices("overlay-host")
    await run(
      services.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, [
        {
          key: mcpOverlayDisableKey("overlay-host", "GitHub"),
          value: { enabled: false },
          timestamp: at(1)
        },
        {
          key: mcpOverlayDisableKey("overlay-host", "odd|name"),
          value: { enabled: false },
          timestamp: at(2)
        },
        {
          key: mcpOverlayDisableKey("other-machine", "GitHub"),
          value: { enabled: false },
          timestamp: at(3)
        },
        {
          key: mcpOverlayDisableKey("overlay-host", "Revived"),
          value: null,
          deleted: true,
          timestamp: at(4)
        },
        {
          key: mcpOverlayDisableKey("overlay-host", "Kept"),
          value: { enabled: true },
          timestamp: at(5)
        },
        { key: "enable|", value: { enabled: false }, timestamp: at(9) },
        { key: "enable|overlay-host", value: { enabled: false }, timestamp: at(10) },
        { key: "unrelated", value: 1, timestamp: at(12) }
      ])
    )
    const overlays = await readMcpOverlays(services.db, "overlay-host")
    expect([...overlays.disabledHere].toSorted()).toEqual(["GitHub", "odd|name"])
  })
})

const server = (connectionState: string, enabled = true, detail?: string) => ({
  name: "S",
  enabled,
  connectionState,
  ...(detail === undefined ? {} : { detail })
})

describe("mcp readiness mapping", () => {
  it("maps live connection states, with overlays outranking them", () => {
    expect(mcpReadiness(server("connected"), none)).toEqual({ name: "S", state: "ready" })
    expect(mcpReadiness(server("connecting"), none)).toEqual({ name: "S", state: "connecting" })
    expect(mcpReadiness(server("disconnected"), none)).toEqual({ name: "S", state: "idle" })
    expect(mcpReadiness(server("needsSetup"), none)).toEqual({
      name: "S",
      state: "blocked",
      code: "needsSetup",
      reason: "Needs setup on this machine"
    })
    expect(mcpReadiness(server("error", true, "spawn npx ENOENT"), none)).toEqual({
      name: "S",
      state: "blocked",
      code: "error",
      reason: "spawn npx ENOENT"
    })
    expect(mcpReadiness(server("someFutureState"), none).reason).toBe("someFutureState")
    expect(mcpReadiness(server("connected", false), none)).toEqual({
      name: "S",
      state: "disabled",
      reason: "Disabled for the whole fleet"
    })
    const disabled: McpOverlays = { disabledHere: new Set(["S"]) }
    expect(mcpReadiness(server("connected"), disabled)).toEqual({
      name: "S",
      state: "disabled",
      reason: "Disabled on this machine"
    })
  })

  it("carries the tool count on a ready row so the fleet list can show drift", () => {
    expect(mcpReadiness({ ...server("connected"), toolCount: 14 }, none)).toEqual({
      name: "S",
      state: "ready",
      toolCount: 14
    })
    expect(mcpReadiness({ ...server("connected"), toolCount: 0 }, none)).toEqual({
      name: "S",
      state: "ready",
      toolCount: 0
    })
    expect(mcpReadiness(server("connected"), none)).toEqual({ name: "S", state: "ready" })
    expect(mcpReadiness({ ...server("connecting"), toolCount: 9 }, none)).toEqual({
      name: "S",
      state: "connecting"
    })
  })
})

describe("publishMcpReadiness", () => {
  it("publishes one single-writer entry per machine, only on change", async () => {
    const { services } = await makeServices("ready-host")
    if (services.mcp === undefined) throw new Error("mcp unavailable")
    const deps = { db: services.db, mcp: services.mcp, serverId: "ready-host" }

    const first = await publishMcpReadiness(deps)
    expect(first.changedEntries).toHaveLength(1)
    expect(first.changedEntries[0]?.key).toBe("ready-host")
    const value = first.changedEntries[0]?.value as {
      servers: Array<{ name: string; state: string }>
    }
    expect(value.servers.map((s) => s.name)).toContain("Computer Use")
    expect(value.servers.map((s) => s.name)).toEqual(
      value.servers.map((s) => s.name).toSorted((a, b) => a.localeCompare(b))
    )

    expect((await publishMcpReadiness(deps)).changedEntries).toEqual([])

    const target = value.servers[0]?.name ?? ""
    await run(
      services.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, [
        {
          key: mcpOverlayDisableKey("ready-host", target),
          value: { enabled: false },
          timestamp: at(1)
        }
      ])
    )
    const second = await publishMcpReadiness(deps)
    expect(second.changedEntries).toHaveLength(1)
    const updated = second.changedEntries[0]?.value as {
      servers: Array<{ name: string; state: string; reason?: string }>
    }
    expect(updated.servers.find((s) => s.name === target)?.state).toBe("disabled")
    const document = await run(services.db.getSyncEntries(MCP_READINESS_NAMESPACE))
    expect(document).toHaveLength(1)
  })
})
