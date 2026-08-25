import { describe, expect, it } from "vitest"
import { makeServices, run } from "../test-support.js"
import { MCPS_SYNC_NAMESPACE, reconcileMcps } from "./config-sync.js"

/// Split from config-sync.test.ts for the size cap: every malformed,
/// junk-shaped, or wrong-transport replica value the MCP reconcile must
/// shrug off without driving changes.
const oauthSeed = (name: string, oauth: unknown) => ({
  authType: "oauth",
  enabled: false,
  name,
  oauth,
  transport: "http",
  url: `https://${name.toLowerCase()}.example.com/mcp`
})

describe("config sync malformed values", () => {
  it("skips malformed replica values", { timeout: 30_000 }, async () => {
    const { services } = await makeServices("server-c")
    if (services.mcp === undefined) throw new Error("mcp unavailable")
    await run(
      services.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
        { key: "junk", value: "nope", timestamp: { wallMs: 1, counter: 0, deviceId: "z" } },
        {
          key: "half",
          value: { name: "half" },
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        },
        {
          key: "bad-transport",
          value: { enabled: true, name: "x", transport: "carrier-pigeon" },
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        },
        {
          key: "bad-auth",
          value: { authType: "psychic", enabled: true, name: "x", transport: "http" },
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        },
        {
          key: "bad-enabled",
          value: { authType: "none", enabled: "yes", name: "x", transport: "http" },
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        },
        {
          key: "nameless",
          value: {},
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        },
        {
          key: "ghost",
          value: null,
          deleted: true,
          timestamp: { wallMs: 1, counter: 0, deviceId: "z" }
        }
      ])
    )
    // A definition this machine once applied, deleted locally, whose
    // replica entry is ALREADY a tombstone: nothing to republish.
    await run(
      services.db.mergeSyncEntries("local.mcps-applied", [
        { key: "ghost", value: "stale-fp", timestamp: { wallMs: 1, counter: 0, deviceId: "c" } }
      ])
    )
    const result = await reconcileMcps({
      db: services.db,
      mcp: services.mcp,
      now: () => 1_000,
      serverId: "server-c"
    })
    expect(result.status).toEqual({ published: [], applied: [], removed: [], renamed: [] })

    // A structurally valid entry with junk in args keeps only the strings,
    // and one without args at all defaults to none.
    await run(
      services.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
        {
          key: "Mixed Args",
          value: {
            args: ["keep", 42, "also"],
            authType: "none",
            bearerToken: 42,
            enabled: false,
            env: { BAD: 2, GOOD: "1" },
            headers: "nope",
            name: "Mixed Args",
            transport: "http",
            url: "https://mixed.example.com/mcp"
          },
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        {
          key: "No Args",
          value: {
            authType: "none",
            bearerToken: "",
            enabled: false,
            headers: {},
            name: "No Args",
            transport: "http",
            url: "https://noargs.example.com/mcp"
          },
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        // OAuth envelope junk in every flavor: each malformed field drops
        // the envelope (the server still applies, tokenless), and material
        // owned by THIS machine is never imported.
        {
          key: "OAuthy1",
          value: oauthSeed("OAuthy1", "str"),
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        {
          key: "OAuthy2",
          value: oauthSeed("OAuthy2", { owner: 1, rotatedAtMs: 1, material: "{}" }),
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        {
          key: "OAuthy3",
          value: oauthSeed("OAuthy3", { owner: "x", rotatedAtMs: "y", material: "{}" }),
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        {
          key: "OAuthy4",
          value: oauthSeed("OAuthy4", { owner: "x", rotatedAtMs: 1, material: 2 }),
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        {
          key: "OAuthMine",
          value: oauthSeed("OAuthMine", {
            owner: "server-c",
            rotatedAtMs: 1,
            material: JSON.stringify({ tokens: { access_token: "mine" }, tokensSavedAt: 1 })
          }),
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        },
        {
          key: "Mixed Env",
          value: {
            command: "echo",
            authType: "none",
            bearerToken: "junk-b",
            enabled: false,
            env: { BAD: 2, GOOD: "1" },
            headers: { "X-Wrong": "1" },
            name: "Mixed Env",
            transport: "stdio"
          },
          timestamp: { wallMs: 2, counter: 0, deviceId: "z" }
        }
      ])
    )
    const mixed = await reconcileMcps({
      db: services.db,
      mcp: services.mcp,
      serverId: "server-c"
    })
    expect([...mixed.status.applied].sort()).toEqual([
      "Mixed Args",
      "Mixed Env",
      "No Args",
      "OAuthMine",
      "OAuthy1",
      "OAuthy2",
      "OAuthy3",
      "OAuthy4"
    ])
    // Envelope junk never smuggled material in — and self-owned material
    // is authority, not an import (no tokens exist here, so no ownership).
    for (const name of ["OAuthy1", "OAuthy2", "OAuthy3", "OAuthy4", "OAuthMine"]) {
      const id = (await services.mcp.list()).find((server) => server.name === name)?.id ?? ""
      expect(await services.mcp.oauthSyncState(id)).toBeUndefined()
    }
    expect(
      (await services.mcp.list()).find((server) => server.name === "Mixed Args")?.args
    ).toEqual(["keep", "also"])
    expect((await services.mcp.list()).find((server) => server.name === "No Args")?.args).toEqual(
      []
    )
    // Junk secret shapes filter down to their string-valued survivors —
    // and wrong-transport material (env on http, headers on stdio) is
    // stripped entirely.
    const mixedId =
      (await services.mcp.list()).find((server) => server.name === "Mixed Args")?.id ?? ""
    const mixedSecrets = await services.mcp.staticSecrets(mixedId)
    expect(mixedSecrets.bearerToken).toBeUndefined()
    expect(mixedSecrets.headers).toBeUndefined()
    expect(mixedSecrets.env).toBeUndefined()
    const mixedEnvId =
      (await services.mcp.list()).find((server) => server.name === "Mixed Env")?.id ?? ""
    const mixedEnvSecrets = await services.mcp.staticSecrets(mixedEnvId)
    expect(mixedEnvSecrets.headers).toBeUndefined()
    expect(mixedEnvSecrets.env).toEqual({ GOOD: "1" })
    const noArgsId =
      (await services.mcp.list()).find((server) => server.name === "No Args")?.id ?? ""
    const noArgsSecrets = await services.mcp.staticSecrets(noArgsId)
    expect(noArgsSecrets.bearerToken).toBeUndefined()
    expect(noArgsSecrets.env).toBeUndefined()

    // A replica update carrying an oauth scope applies onto an existing
    // local definition through the update path.
    await services.mcp.create({
      authType: "none",
      enabled: false,
      name: "Scoped2",
      transport: "http",
      url: "https://before.example.com/mcp"
    })
    await reconcileMcps({ db: services.db, mcp: services.mcp, serverId: "server-c" })
    await run(
      services.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
        {
          key: "Scoped2",
          value: {
            args: [],
            authType: "oauth",
            enabled: false,
            name: "Scoped2",
            oauthScope: "repo",
            transport: "http",
            url: "https://after.example.com/mcp"
          },
          timestamp: { wallMs: 99_999_999_999_999, counter: 0, deviceId: "far" }
        }
      ])
    )
    const scoped = await reconcileMcps({
      db: services.db,
      mcp: services.mcp,
      serverId: "server-c"
    })
    expect(scoped.status.applied).toContain("Scoped2")
    expect((await services.mcp.list()).find((server) => server.name === "Scoped2")).toMatchObject({
      oauthScope: "repo",
      url: "https://after.example.com/mcp"
    })
  })
})
