import { describe, expect, it } from "vitest"
import { makeServices, run } from "../test-support.js"
import {
  ACCOUNTS_SYNC_NAMESPACE,
  MCPS_SYNC_NAMESPACE,
  publishAccountsRoster,
  reconcileMcps
} from "./config-sync.js"

describe("config sync", () => {
  it(
    "replicates MCP definitions across machines without secrets",
    { timeout: 30_000 },
    async () => {
      const { services: machineA } = await makeServices("server-a")
      const { services: machineB } = await makeServices("server-b")
      const mcpA = machineA.mcp
      const mcpB = machineB.mcp
      if (mcpA === undefined || mcpB === undefined) throw new Error("mcp unavailable")
      const a = { db: machineA.db, mcp: mcpA, serverId: "server-a" }
      const b = { db: machineB.db, mcp: mcpB, serverId: "server-b" }

      await mcpA.create({
        authType: "bearer",
        bearerToken: "secret-token",
        enabled: true,
        name: "GitHub",
        transport: "http",
        url: "https://api.example.com/mcp"
      })
      // A stdio definition and an OAuth-scoped one ride along, covering the
      // command and scope fields end to end.
      await mcpA.create({
        args: ["-y", "some-mcp"],
        enabled: true,
        name: "Local Tool",
        command: "npx",
        transport: "stdio"
      })
      await mcpA.create({
        authType: "oauth",
        enabled: true,
        name: "Scoped",
        oauthScope: "repo",
        transport: "http",
        url: "https://oauth.example.com/mcp"
      })
      const firstA = await reconcileMcps(a)
      expect([...firstA.status.published].sort()).toEqual(["GitHub", "Local Tool", "Scoped"])
      // Secrets never enter the replica.
      expect(JSON.stringify(firstA.changedEntries)).not.toContain("secret-token")
      // Idempotent second pass.
      expect((await reconcileMcps(a)).status).toEqual({ published: [], applied: [], removed: [] })

      // B adopts the definitions.
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, firstA.changedEntries))
      const appliedB = await reconcileMcps(b)
      expect([...appliedB.status.applied].sort()).toEqual(["GitHub", "Local Tool", "Scoped"])
      const listB = await mcpB.list()
      const githubB = listB.find((server) => server.name === "GitHub")
      expect(githubB).toMatchObject({ url: "https://api.example.com/mcp", authType: "bearer" })
      expect(listB.find((server) => server.name === "Local Tool")).toMatchObject({
        command: "npx",
        transport: "stdio"
      })
      expect(listB.find((server) => server.name === "Scoped")).toMatchObject({
        oauthScope: "repo"
      })

      // Edits on B (http and stdio alike) replicate back to A.
      await mcpB.update(githubB?.id ?? "", { enabled: false })
      const localToolB = listB.find((server) => server.name === "Local Tool")
      await mcpB.update(localToolB?.id ?? "", { args: ["-y", "other-mcp"] })
      const editedB = await reconcileMcps(b)
      expect([...editedB.status.published].sort()).toEqual(["GitHub", "Local Tool"])
      await run(machineA.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, editedB.changedEntries))
      const appliedA = await reconcileMcps(a)
      expect([...appliedA.status.applied].sort()).toEqual(["GitHub", "Local Tool"])
      expect((await mcpA.list()).find((server) => server.name === "GitHub")?.enabled).toBe(false)
      expect((await mcpA.list()).find((server) => server.name === "Local Tool")?.args).toEqual([
        "-y",
        "other-mcp"
      ])

      // A deletion tombstones everywhere.
      const idA = (await mcpA.list()).find((server) => server.name === "GitHub")?.id ?? ""
      await mcpA.remove(idA)
      const removedA = await reconcileMcps(a)
      expect(removedA.status.published).toEqual(["GitHub"])
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, removedA.changedEntries))
      const removedB = await reconcileMcps(b)
      expect(removedB.status.removed).toEqual(["GitHub"])
      expect((await mcpB.list()).some((server) => server.name === "GitHub")).toBe(false)
    }
  )

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
    expect(result.status).toEqual({ published: [], applied: [], removed: [] })

    // A structurally valid entry with junk in args keeps only the strings,
    // and one without args at all defaults to none.
    await run(
      services.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
        {
          key: "Mixed Args",
          value: {
            args: ["keep", 42, "also"],
            authType: "none",
            enabled: false,
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
            enabled: false,
            name: "No Args",
            transport: "http",
            url: "https://noargs.example.com/mcp"
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
    expect([...mixed.status.applied].sort()).toEqual(["Mixed Args", "No Args"])
    expect(
      (await services.mcp.list()).find((server) => server.name === "Mixed Args")?.args
    ).toEqual(["keep", "also"])
    expect((await services.mcp.list()).find((server) => server.name === "No Args")?.args).toEqual(
      []
    )

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

  it("publishes each machine's account roster once per change", async () => {
    const { services } = await makeServices("server-d")
    await run(
      services.db.saveHarnessAccount({
        authState: "authenticated",
        canLogin: true,
        canLogout: true,
        email: "u@example.com",
        harnessId: "claude-code",
        label: "Personal",
        profileKind: "default"
      })
    )
    // A second account without an email exercises the optional field.
    await run(
      services.db.saveHarnessAccount({
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false,
        harnessId: "claude-code",
        label: "Work",
        profileKind: "managed"
      })
    )
    const deps = {
      db: services.db,
      harnessIds: ["claude-code"],
      now: () => 5_000,
      serverId: "server-d"
    }
    const first = await publishAccountsRoster(deps)
    expect(first.changedEntries).toHaveLength(1)

    // An unchanged roster republishes nothing.
    expect((await publishAccountsRoster(deps)).changedEntries).toEqual([])

    const document = await run(services.db.getSyncEntries(ACCOUNTS_SYNC_NAMESPACE))
    expect(document[0]?.key).toBe("server-d")
    const roster = document[0]?.value as {
      readonly accounts: ReadonlyArray<{ readonly label: string; readonly email?: string }>
    }
    expect(roster.accounts).toHaveLength(2)
    expect(roster.accounts.some((account) => account.label === "Personal")).toBe(true)
    expect(roster.accounts.find((account) => account.label === "Work")?.email).toBeUndefined()
  })
})
