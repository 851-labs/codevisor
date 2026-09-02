import { describe, expect, it } from "vitest"
import { makeServices, run } from "../test-support.js"
import {
  ACCOUNTS_SYNC_NAMESPACE,
  MCPS_SYNC_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  PLUGIN_READINESS_NAMESPACE,
  publishAccountsRoster,
  publishMachineReadiness,
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
        headers: { "X-Keep": "k", "X-Org": "851" },
        name: "GitHub",
        transport: "http",
        url: "https://api.example.com/mcp"
      })
      // A stdio definition and an OAuth-scoped one ride along, covering the
      // command and scope fields end to end. Enabled definitions connect
      // eagerly on create/update, on both machines: the command must fail at
      // spawn (ENOENT) rather than be a real `npx -y …`, which installs from
      // the registry on a cold CI runner and pushes this test past its budget.
      await mcpA.create({
        args: ["-y", "some-mcp"],
        enabled: true,
        env: { KEEP: "k", TOKEN: "t1" },
        name: "Local Tool",
        command: "codevisor-test-missing-mcp",
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
      // Static secrets travel with the definition (same-owner fleet trust);
      // OAuth material never does.
      expect(JSON.stringify(firstA.changedEntries)).toContain("secret-token")
      // Idempotent second pass.
      expect((await reconcileMcps(a)).status).toEqual({
        published: [],
        applied: [],
        removed: [],
        renamed: []
      })

      // B adopts the definitions.
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, firstA.changedEntries))
      const appliedB = await reconcileMcps(b)
      expect([...appliedB.status.applied].sort()).toEqual(["GitHub", "Local Tool", "Scoped"])
      const listB = await mcpB.list()
      const githubB = listB.find((server) => server.name === "GitHub")
      expect(githubB).toMatchObject({ url: "https://api.example.com/mcp", authType: "bearer" })
      expect(listB.find((server) => server.name === "Local Tool")).toMatchObject({
        command: "codevisor-test-missing-mcp",
        transport: "stdio"
      })
      expect(listB.find((server) => server.name === "Scoped")).toMatchObject({
        oauthScope: "repo"
      })
      // Static secrets arrived with the definitions: a key-based server
      // works here with zero re-entry.
      const githubSecretsB = await mcpB.staticSecrets(githubB?.id ?? "")
      expect(githubSecretsB.bearerToken).toBe("secret-token")
      expect(githubSecretsB.headers).toEqual({ "X-Keep": "k", "X-Org": "851" })
      const localToolIdB = listB.find((server) => server.name === "Local Tool")?.id ?? ""
      expect((await mcpB.staticSecrets(localToolIdB)).env).toEqual({ KEEP: "k", TOKEN: "t1" })

      // Edits on B (http and stdio alike) replicate back to A.
      await mcpB.update(githubB?.id ?? "", {
        enabled: false,
        bearerToken: "",
        headers: { "X-New": "1" },
        removeHeaders: ["X-Org"]
      })
      const localToolB = listB.find((server) => server.name === "Local Tool")
      await mcpB.update(localToolB?.id ?? "", {
        args: ["-y", "other-mcp"],
        env: { KEEP: "k2" },
        removeEnv: ["TOKEN"]
      })
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
      // Secret edits converged exactly: the cleared bearer stays cleared,
      // removed headers/env are gone, additions and kept values landed.
      const githubIdA = (await mcpA.list()).find((server) => server.name === "GitHub")?.id ?? ""
      const githubSecretsA = await mcpA.staticSecrets(githubIdA)
      expect(githubSecretsA.bearerToken).toBeUndefined()
      expect(githubSecretsA.headers).toEqual({ "X-Keep": "k", "X-New": "1" })
      const localToolIdA =
        (await mcpA.list()).find((server) => server.name === "Local Tool")?.id ?? ""
      expect((await mcpA.staticSecrets(localToolIdA)).env).toEqual({ KEEP: "k2" })

      // A rotated bearer travels back the other way on the next round.
      await mcpA.update(githubIdA, { bearerToken: "rotated" })
      const rotatedA = await reconcileMcps(a)
      expect(rotatedA.status.published).toEqual(["GitHub"])
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, rotatedA.changedEntries))
      await reconcileMcps(b)
      expect((await mcpB.staticSecrets(githubB?.id ?? "")).bearerToken).toBe("rotated")

      // Emptying a stdio server's env converges to nothing everywhere.
      await mcpB.update(localToolB?.id ?? "", { removeEnv: ["KEEP"] })
      const emptiedB = await reconcileMcps(b)
      expect(emptiedB.status.published).toEqual(["Local Tool"])
      await run(machineA.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, emptiedB.changedEntries))
      await reconcileMcps(a)
      expect((await mcpA.staticSecrets(localToolIdA)).env).toBeUndefined()

      // OAuth under refresh ownership: A authorizes (modeled by importing
      // material owned by itself), publishes the envelope, and B mirrors it
      // WITHOUT becoming an owner.
      const scopedIdA = (await mcpA.list()).find((server) => server.name === "Scoped")?.id ?? ""
      await mcpA.importOAuthMaterial(scopedIdA, {
        owner: "server-a",
        material: JSON.stringify({
          tokens: { access_token: "at-1", refresh_token: "rt-1", token_type: "bearer" },
          tokensSavedAt: 1_000
        })
      })
      expect((await mcpA.oauthSyncState(scopedIdA))?.owner).toBe("server-a")
      const oauthA = await reconcileMcps(a)
      expect(oauthA.status.published).toEqual(["Scoped"])
      const envelope = (
        oauthA.changedEntries.find((entry) => entry.key === "Scoped")?.value as {
          oauth?: { owner: string }
        }
      ).oauth
      expect(envelope?.owner).toBe("server-a")
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, oauthA.changedEntries))
      await reconcileMcps(b)
      // B mirrors the material — visible, attributed to A, never owned.
      const scopedIdB = (await mcpB.list()).find((server) => server.name === "Scoped")?.id ?? ""
      expect((await mcpB.oauthSyncState(scopedIdB))?.owner).toBe("server-a")
      // A settled mirror republishes nothing.
      await reconcileMcps(b)
      expect((await reconcileMcps(b)).changedEntries).toEqual([])

      // B re-authorizes: ownership transfers, and A demotes to a mirror.
      await mcpB.importOAuthMaterial(scopedIdB, {
        owner: "server-b",
        material: JSON.stringify({
          tokens: { access_token: "at-2", refresh_token: "rt-2", token_type: "bearer" },
          tokensSavedAt: 2_000
        })
      })
      const takeoverB = await reconcileMcps(b)
      expect(takeoverB.status.published).toEqual(["Scoped"])
      await run(machineA.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, takeoverB.changedEntries))
      await reconcileMcps(a)
      expect((await mcpA.oauthSyncState(scopedIdA))?.owner).toBe("server-b")

      // A brand-new machine creates the server AND adopts the material in
      // the same pass — zero logins on a fresh box.
      const { services: machineC } = await makeServices("server-c2")
      if (machineC.mcp === undefined) throw new Error("mcp unavailable")
      const c = { db: machineC.db, mcp: machineC.mcp, serverId: "server-c2" }
      await run(machineC.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, takeoverB.changedEntries))
      const freshC = await reconcileMcps(c)
      expect(freshC.status.applied).toEqual(["Scoped"])
      const scopedIdC =
        (await machineC.mcp.list()).find((server) => server.name === "Scoped")?.id ?? ""
      expect((await machineC.mcp.oauthSyncState(scopedIdC))?.owner).toBe("server-b")

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

  it("publishes a machine readiness entry once per change, keyed by machine", async () => {
    const { services } = await makeServices("server-p")
    const deps = {
      db: services.db,
      namespace: PLUGIN_READINESS_NAMESPACE,
      now: () => 9_000,
      serverId: "server-p",
      value: {
        plugins: [
          { id: "dev-linked", state: "machineOnly" },
          { id: "ffmpeg-tools", state: "blocked", reason: "needs ffmpeg" },
          { id: "scratchpad", state: "ready" }
        ]
      }
    }
    const first = await publishMachineReadiness(deps)
    expect(first.changedEntries).toHaveLength(1)
    // A settled machine republishes nothing.
    expect((await publishMachineReadiness(deps)).changedEntries).toEqual([])

    const document = await run(services.db.getSyncEntries(PLUGIN_READINESS_NAMESPACE))
    expect(document[0]?.key).toBe("server-p")
    const value = document[0]?.value as {
      readonly plugins: ReadonlyArray<{ readonly id: string; readonly reason?: string }>
    }
    expect(value.plugins.map((row) => row.id)).toEqual(["dev-linked", "ffmpeg-tools", "scratchpad"])
    expect(value.plugins[1]?.reason).toBe("needs ffmpeg")

    // The same publisher serves every plane — namespaces stay independent.
    const harness = await publishMachineReadiness({
      db: services.db,
      namespace: HARNESS_READINESS_NAMESPACE,
      serverId: "server-p",
      value: { harnesses: [{ id: "codex", state: "signInRequired" }] }
    })
    expect(harness.changedEntries).toHaveLength(1)
    expect((await run(services.db.getSyncEntries(HARNESS_READINESS_NAMESPACE)))[0]?.key).toBe(
      "server-p"
    )
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

  it(
    "adopts identical and renames conflicting first-contact definitions",
    { timeout: 30_000 },
    async () => {
      const { services } = await makeServices("server-d")
      if (services.mcp === undefined) throw new Error("mcp unavailable")
      const deps = { db: services.db, mcp: services.mcp, serverId: "server-d" }
      const base = { authType: "none" as const, enabled: false, transport: "http" as const }

      // Never-synced local definitions: a conflicting GitHub, a decoy
      // occupying a rename candidate, an identical Same, and a name the
      // replica only remembers as a tombstone.
      await services.mcp.create({ ...base, name: "GitHub", url: "https://local.example/mcp" })
      await services.mcp.create({ ...base, name: "GitHub-3", url: "https://decoy.example/mcp" })
      await services.mcp.create({ ...base, name: "Same", url: "https://same.example/mcp" })
      await services.mcp.create({ ...base, name: "Ghost", url: "https://ghost.example/mcp" })
      const value = (name: string, url: string) => ({
        name,
        transport: "http",
        url,
        args: [],
        enabled: false,
        authType: "none"
      })
      const at = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })
      await run(
        services.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
          {
            key: "GitHub",
            value: value("GitHub", "https://fleet.example/mcp"),
            timestamp: at(10)
          },
          {
            key: "GitHub-2",
            value: value("GitHub-2", "https://fleet2.example/mcp"),
            timestamp: at(11)
          },
          { key: "Same", value: value("Same", "https://same.example/mcp"), timestamp: at(12) },
          { key: "Ghost", value: null, deleted: true, timestamp: at(13) }
        ])
      )

      const result = await reconcileMcps(deps)

      // GitHub-2 is taken in the replica and GitHub-3 locally, so the
      // local copy became GitHub-4; Same was adopted in place; Ghost
      // republished over the stale tombstone.
      expect(result.status.renamed).toEqual([{ from: "GitHub", to: "GitHub-4" }])
      expect([...result.status.published].sort()).toEqual(["Ghost", "GitHub-3", "GitHub-4"])
      expect([...result.status.applied].sort()).toEqual(["GitHub", "GitHub-2"])
      const list = await services.mcp.list()
      expect(list.find((s) => s.name === "GitHub-4")?.url).toBe("https://local.example/mcp")
      expect(list.find((s) => s.name === "GitHub")?.url).toBe("https://fleet.example/mcp")
      expect(list.find((s) => s.name === "GitHub-2")?.url).toBe("https://fleet2.example/mcp")
      expect(list.filter((s) => s.name === "Same")).toHaveLength(1)
    }
  )
})
