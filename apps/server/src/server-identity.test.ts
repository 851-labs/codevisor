import { describe, expect, it } from "vitest"
import { defaultServerConfig, startCodevisorServer } from "./server.js"
import { MCPS_SYNC_NAMESPACE } from "./infra/config-sync.js"
import { MCP_OVERLAYS_NAMESPACE, readMcpOverlays } from "./infra/mcp-fleet.js"
import { makeServices, run, runningServers, waitFor } from "./test-support.js"

describe("server boot identity", () => {
  it("adopts legacy 'local' overlays at boot and announces the change", async () => {
    const { services } = await makeServices("machine-abc")
    await run(
      services.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, [
        {
          key: "enable|local|GitHub",
          value: { enabled: false },
          timestamp: { wallMs: 1, counter: 0, deviceId: "phone" }
        }
      ])
    )
    const server = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "machine-abc", kind: "local", port: 0 })
      )
    )
    runningServers.push(server)

    await waitFor(async () =>
      (await readMcpOverlays(services.db, "machine-abc")).disabledHere.has("GitHub")
    )
    const overlayAnnouncements = async () =>
      (await run(services.db.listEvents(0))).filter(
        (event) => event.kind === "sync.changed" && event.subjectId === MCP_OVERLAYS_NAMESPACE
      )
    await waitFor(async () => (await overlayAnnouncements()).length > 0)
    const announced = await overlayAnnouncements()
    expect(announced).toHaveLength(1)
    expect(announced[0]?.payload).toMatchObject({
      namespace: MCP_OVERLAYS_NAMESPACE,
      entries: expect.arrayContaining([
        expect.objectContaining({ key: "enable|machine-abc|GitHub" }),
        expect.objectContaining({ key: "enable|local|GitHub", deleted: true })
      ])
    })
    // The adopted overlay is enforced, not just recorded.
    await waitFor(async () =>
      (await services.mcp!.resolved()).every((candidate) => candidate.name !== "GitHub")
    )
  })

  it("takes over refreshing tokens it authorized under the former 'local' identity", async () => {
    const { services } = await makeServices("machine-abc")
    const mcp = services.mcp!
    const server = await mcp.create({
      authType: "oauth",
      name: "Sentry",
      transport: "http",
      url: "https://sentry.example.test/mcp"
    })
    await mcp.importOAuthMaterial(server.id, {
      owner: "local",
      material: JSON.stringify({
        tokens: { access_token: "at", refresh_token: "rt", token_type: "bearer" },
        tokensSavedAt: 10
      })
    })
    const running = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ id: "machine-abc", kind: "local", port: 0 })
      )
    )
    runningServers.push(running)

    await waitFor(async () => (await mcp.oauthSyncState(server.id))?.owner === "machine-abc")
    // The republish carries the new owner to every mirror.
    await waitFor(async () =>
      (await run(services.db.getSyncEntries(MCPS_SYNC_NAMESPACE))).some(
        (entry) =>
          entry.key === "Sentry" &&
          (entry.value as { oauth?: { owner?: string } }).oauth?.owner === "machine-abc"
      )
    )
  })
})
