import { describe, expect, it } from "vitest"
import { makeServices, run } from "../test-support.js"
import { ACCOUNTS_SYNC_NAMESPACE } from "./config-sync.js"
import { MCP_OVERLAYS_NAMESPACE, MCP_READINESS_NAMESPACE, readMcpOverlays } from "./mcp-fleet.js"
import { adoptLegacySyncIdentity } from "./sync-identity.js"

const at = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "phone" })

const live = async (
  db: Awaited<ReturnType<typeof makeServices>>["services"]["db"],
  namespace: string
) =>
  (await run(db.getSyncEntries(namespace)))
    .filter((entry) => entry.deleted !== true)
    .map((entry) => entry.key)
    .toSorted()

describe("legacy sync identity adoption", () => {
  it("moves an app-hosted machine's 'local' overlays and readiness under its stable id", async () => {
    const { services } = await makeServices("machine-abc")
    await run(
      services.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, [
        { key: "enable|local|GitHub", value: { enabled: false }, timestamp: at(1) },
        // Already disabled under the real id: the legacy twin only tombstones.
        { key: "enable|local|Kept", value: { enabled: false }, timestamp: at(2) },
        { key: "enable|machine-abc|Kept", value: { enabled: false }, timestamp: at(3) },
        // Someone else's overlay is not ours to touch.
        { key: "enable|machine-xyz|GitHub", value: { enabled: false }, timestamp: at(4) },
        { key: "enable|local|Gone", value: null, deleted: true, timestamp: at(5) },
        // A malformed legacy key (no name) is left alone.
        { key: "enable|local|", value: { enabled: false }, timestamp: at(6) }
      ])
    )
    await run(
      services.db.mergeSyncEntries(MCP_READINESS_NAMESPACE, [
        { key: "local", value: { servers: [] }, timestamp: at(1) },
        { key: "machine-xyz", value: { servers: [] }, timestamp: at(2) }
      ])
    )
    await run(
      services.db.mergeSyncEntries(ACCOUNTS_SYNC_NAMESPACE, [
        { key: "local", value: { accounts: [] }, timestamp: at(1) }
      ])
    )

    const result = await adoptLegacySyncIdentity({
      db: services.db,
      serverId: "machine-abc",
      kind: "local"
    })
    expect(result.changed.map((change) => change.namespace).toSorted()).toEqual(
      [MCP_OVERLAYS_NAMESPACE, MCP_READINESS_NAMESPACE, ACCOUNTS_SYNC_NAMESPACE].toSorted()
    )
    expect(await live(services.db, MCP_OVERLAYS_NAMESPACE)).toEqual([
      "enable|local|",
      "enable|machine-abc|GitHub",
      "enable|machine-abc|Kept",
      "enable|machine-xyz|GitHub"
    ])
    expect(
      [...(await readMcpOverlays(services.db, "machine-abc")).disabledHere].toSorted()
    ).toEqual(["GitHub", "Kept"])
    expect(await live(services.db, MCP_READINESS_NAMESPACE)).toEqual(["machine-xyz"])
    expect(await live(services.db, ACCOUNTS_SYNC_NAMESPACE)).toEqual([])

    // Settled: a second pass changes nothing.
    expect(
      await adoptLegacySyncIdentity({ db: services.db, serverId: "machine-abc", kind: "local" })
    ).toEqual({ changed: [], adoptedOAuth: [] })
  })

  it("never lets a remote machine, or a still-'local' one, claim legacy entries", async () => {
    const { services } = await makeServices("machine-remote")
    await run(
      services.db.mergeSyncEntries(MCP_OVERLAYS_NAMESPACE, [
        { key: "enable|local|GitHub", value: { enabled: false }, timestamp: at(1) }
      ])
    )
    await run(
      services.db.mergeSyncEntries(MCP_READINESS_NAMESPACE, [
        { key: "local", value: { servers: [] }, timestamp: at(1) }
      ])
    )
    for (const deps of [
      { serverId: "machine-remote", kind: "remote" as const },
      { serverId: "local", kind: "local" as const }
    ]) {
      expect((await adoptLegacySyncIdentity({ db: services.db, ...deps })).changed).toEqual([])
    }
    expect(await live(services.db, MCP_OVERLAYS_NAMESPACE)).toEqual(["enable|local|GitHub"])
    expect(await live(services.db, MCP_READINESS_NAMESPACE)).toEqual(["local"])
  })
})
