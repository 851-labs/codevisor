import { describe, expect, it } from "vitest"

import { MCPS_SYNC_NAMESPACE } from "./infra/config-sync.js"
import { MCP_OVERLAYS_NAMESPACE, readMcpOverlays } from "./infra/mcp-fleet.js"
import {
  machineVault,
  manualOAuthClock,
  seedLegacyMcpOAuth,
  sharedCoordinator,
  tempDirectory
} from "./infra/mcp-oauth-test-support.js"
import { defaultServerConfig, startCodevisorServer } from "./server.js"
import { makeServices, run, runningServers, waitFor, listEvents } from "./test-support.js"
import { field } from "./unknown-values.js"

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
        defaultServerConfig({ bootId: "test-boot", id: "machine-abc", kind: "local", port: 0 })
      )
    )
    runningServers.push(server)

    await waitFor(async () =>
      (await readMcpOverlays(services.db, "machine-abc")).disabledHere.has("GitHub")
    )
    const overlayAnnouncements = async () =>
      listEvents(services).filter(
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
    await waitFor(async () =>
      (await services.mcp.resolved()).every((candidate) => candidate.name !== "GitHub")
    )
  })

  it("moves tokens it authorized under the former 'local' identity into the shared vault", async () => {
    const clock = manualOAuthClock()
    const coordinator = sharedCoordinator(clock)
    const { services } = await makeServices("machine-abc", {
      oauthVault: machineVault(coordinator, "machine-abc", clock, await tempDirectory()),
      oauthClock: clock
    })
    const mcp = services.mcp
    const server = await mcp.create({
      authType: "oauth",
      name: "Sentry",
      transport: "http",
      url: "https://sentry.example.test/mcp"
    })
    await seedLegacyMcpOAuth(services, server.id, {
      refreshOwner: "local",
      tokens: { access_token: "at", refresh_token: "rt", token_type: "bearer" },
      tokensSavedAt: 10,
      clientInformation: { client_id: "registered" },
      discoveryState: { authorizationServerUrl: "https://auth.sentry.example.test" }
    })
    const running = await run(
      startCodevisorServer(
        services,
        defaultServerConfig({ bootId: "test-boot", id: "machine-abc", kind: "local", port: 0 })
      )
    )
    runningServers.push(running)

    await waitFor(async () => (await mcp.oauthCredential(server.id)) != null)
    const credential = await mcp.oauthCredential(server.id)
    expect(coordinator.records.get(credential?.id ?? "")?.generation).toBe(1)
    await waitFor(async () =>
      (await run(services.db.getSyncEntries(MCPS_SYNC_NAMESPACE))).some(
        (entry) =>
          entry.key === "Sentry" &&
          field(field(entry.value, "oauthCredential"), "id") === credential?.id
      )
    )
  })
})
