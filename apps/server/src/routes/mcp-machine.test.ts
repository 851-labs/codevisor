import { describe, expect, it, vi } from "vitest"
import { jsonRequest, makeServices, run, start, startWithApp } from "../test-support.js"

describe("machine-specific MCP availability", () => {
  it("uses the same overlay as Settings while preserving the fleet definition", async () => {
    const { server, services } = await start()
    const path = "/v1/mcps/codevisor/machine-state"
    expect(await jsonRequest(server, path)).toMatchObject({
      status: 200,
      body: { enabled: true, disabledHere: false }
    })
    expect(
      await jsonRequest(server, path, { method: "PUT", body: JSON.stringify({ enabled: false }) })
    ).toMatchObject({
      status: 200,
      body: { machineId: "server-a", disabledHere: true, enabled: false, server: { enabled: true } }
    })
    const entries = await run(services.db.getSyncEntries("mcp-overlays"))
    expect(entries).toMatchObject([{ key: "enable|server-a|Codevisor", value: { enabled: false } }])
    await services.mcp.update("codevisor", { enabled: false })
    expect(
      await jsonRequest(server, path, { method: "PUT", body: JSON.stringify({ enabled: true }) })
    ).toMatchObject({
      status: 200,
      body: { disabledHere: false, enabled: true, server: { enabled: true } }
    })
    expect(await run(services.db.getSyncEntries("mcp-overlays"))).toMatchObject([{ deleted: true }])
    // An already-enabled definition also clears an override without changing it.
    expect(
      await jsonRequest(server, path, { method: "PUT", body: JSON.stringify({ enabled: true }) })
    ).toMatchObject({ status: 200 })
    expect(await jsonRequest(server, path, { method: "POST" })).toMatchObject({ status: 405 })
    expect(await jsonRequest(server, path, { method: "PUT", body: "{}" })).toMatchObject({
      status: 400
    })
    expect(await jsonRequest(server, "/v1/mcps/missing/machine-state")).toMatchObject({
      status: 404
    })
  })

  it("reports unavailable MCP infrastructure", async () => {
    const { services } = await makeServices("server-a")
    const { mcp: _mcp, ...withoutMcp } = services
    const server = await startWithApp(withoutMcp)
    try {
      expect(await jsonRequest(server, "/v1/mcps/codevisor/machine-state")).toMatchObject({
        status: 501
      })
    } finally {
      await run(server.close)
    }
  })

  it("does not report success if the MCP is removed during the change", async () => {
    const { server, services } = await start()
    const temporary = await services.mcp.create({
      name: "Temporary",
      transport: "stdio",
      command: "unused-command",
      authType: "none",
      enabled: false
    })
    const suppress = services.mcp.setLocalSuppression.bind(services.mcp)
    let removed = false
    const change = vi
      .spyOn(services.mcp, "setLocalSuppression")
      .mockImplementation(async (names) => {
        await suppress(names)
        if (names.has(temporary.name) && !removed) {
          removed = true
          await services.mcp.remove(temporary.id)
        }
      })
    try {
      expect(
        await jsonRequest(server, `/v1/mcps/${temporary.id}/machine-state`, {
          method: "PUT",
          body: JSON.stringify({ enabled: false })
        })
      ).toMatchObject({
        status: 404,
        body: { error: "MCP server was removed while changing availability" }
      })
    } finally {
      change.mockRestore()
    }
  })
})
