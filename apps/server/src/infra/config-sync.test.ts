import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import { field } from "../unknown-values.js"
import {
  ACCOUNTS_SYNC_NAMESPACE,
  MCPS_SYNC_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  publishAccountsRoster,
  publishMachineReadiness,
  reconcileMcps
} from "./config-sync.js"

const mcpValue = (name: string, url: string) => ({
  name,
  transport: "http",
  url,
  args: [],
  enabled: false,
  authType: "none"
})

const credentialReference = (seed: string) => ({
  id: `credential-${seed}-0123456789`,
  key: seed.repeat(43)
})

const elsewhereAt = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "elsewhere" })

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
      expect([...firstA.status.published].toSorted()).toEqual(["GitHub", "Local Tool", "Scoped"])
      expect(JSON.stringify(firstA.changedEntries)).toContain("secret-token")
      expect((await reconcileMcps(a)).status).toEqual({
        published: [],
        applied: [],
        removed: [],
        renamed: []
      })

      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, firstA.changedEntries))
      const appliedB = await reconcileMcps(b)
      expect([...appliedB.status.applied].toSorted()).toEqual(["GitHub", "Local Tool", "Scoped"])
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
      const githubSecretsB = await mcpB.staticSecrets(githubB?.id ?? "")
      expect(githubSecretsB.bearerToken).toBe("secret-token")
      expect(githubSecretsB.headers).toEqual({ "X-Keep": "k", "X-Org": "851" })
      const localToolIdB = listB.find((server) => server.name === "Local Tool")?.id ?? ""
      expect((await mcpB.staticSecrets(localToolIdB)).env).toEqual({ KEEP: "k", TOKEN: "t1" })

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
      expect([...editedB.status.published].toSorted()).toEqual(["GitHub", "Local Tool"])
      await run(machineA.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, editedB.changedEntries))
      const appliedA = await reconcileMcps(a)
      expect([...appliedA.status.applied].toSorted()).toEqual(["GitHub", "Local Tool"])
      expect((await mcpA.list()).find((server) => server.name === "GitHub")?.enabled).toBe(false)
      expect((await mcpA.list()).find((server) => server.name === "Local Tool")?.args).toEqual([
        "-y",
        "other-mcp"
      ])
      const githubIdA = (await mcpA.list()).find((server) => server.name === "GitHub")?.id ?? ""
      const githubSecretsA = await mcpA.staticSecrets(githubIdA)
      expect(githubSecretsA.bearerToken).toBeUndefined()
      expect(githubSecretsA.headers).toEqual({ "X-Keep": "k", "X-New": "1" })
      const localToolIdA =
        (await mcpA.list()).find((server) => server.name === "Local Tool")?.id ?? ""
      expect((await mcpA.staticSecrets(localToolIdA)).env).toEqual({ KEEP: "k2" })

      await mcpA.update(githubIdA, { bearerToken: "rotated" })
      const rotatedA = await reconcileMcps(a)
      expect(rotatedA.status.published).toEqual(["GitHub"])
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, rotatedA.changedEntries))
      await reconcileMcps(b)
      expect((await mcpB.staticSecrets(githubB?.id ?? "")).bearerToken).toBe("rotated")

      await mcpB.update(localToolB?.id ?? "", { removeEnv: ["KEEP"] })
      const emptiedB = await reconcileMcps(b)
      expect(emptiedB.status.published).toEqual(["Local Tool"])
      await run(machineA.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, emptiedB.changedEntries))
      await reconcileMcps(a)
      expect((await mcpA.staticSecrets(localToolIdA)).env).toBeUndefined()

      const scopedIdA = (await mcpA.list()).find((server) => server.name === "Scoped")?.id ?? ""
      const signedInA = credentialReference("a")
      await mcpA.setOAuthCredential(scopedIdA, signedInA)
      const oauthA = await reconcileMcps(a)
      expect(oauthA.status.published).toEqual(["Scoped"])
      const scoped = oauthA.changedEntries.find((entry) => entry.key === "Scoped")
      expect(field(scoped?.value, "oauthCredential")).toEqual(signedInA)
      expect(JSON.stringify(scoped?.value)).not.toContain("access")
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, oauthA.changedEntries))
      await reconcileMcps(b)
      const scopedIdB = (await mcpB.list()).find((server) => server.name === "Scoped")?.id ?? ""
      expect(await mcpB.oauthCredential(scopedIdB)).toEqual(signedInA)
      await reconcileMcps(b)
      expect((await reconcileMcps(b)).changedEntries).toEqual([])

      const signedInB = credentialReference("b")
      await mcpB.setOAuthCredential(scopedIdB, signedInB)
      const resignedB = await reconcileMcps(b)
      expect(resignedB.status.published).toEqual(["Scoped"])
      await run(machineA.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, resignedB.changedEntries))
      await reconcileMcps(a)
      expect(await mcpA.oauthCredential(scopedIdA)).toEqual(signedInB)

      const { services: machineC } = await makeServices("server-c2")
      if (machineC.mcp === undefined) throw new Error("mcp unavailable")
      const c = { db: machineC.db, mcp: machineC.mcp, serverId: "server-c2" }
      await run(machineC.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, resignedB.changedEntries))
      const freshC = await reconcileMcps(c)
      expect(freshC.status.applied).toEqual(["Scoped"])
      const scopedIdC =
        (await machineC.mcp.list()).find((server) => server.name === "Scoped")?.id ?? ""
      expect(await machineC.mcp.oauthCredential(scopedIdC)).toEqual(signedInB)

      await mcpA.setOAuthCredential(scopedIdA, null)
      const signedOutA = await reconcileMcps(a)
      expect(signedOutA.status.published).toEqual(["Scoped"])
      await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, signedOutA.changedEntries))
      await reconcileMcps(b)
      expect(await mcpB.oauthCredential(scopedIdB)).toBeNull()

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

  it("keeps a local MCP that is edited while a remote removal is applied", async () => {
    const { services: machineA } = await makeServices("server-race-a")
    const { services: machineB } = await makeServices("server-race-b")
    const mcpA = machineA.mcp
    const mcpB = machineB.mcp
    if (mcpA === undefined || mcpB === undefined) throw new Error("mcp unavailable")
    const a = { db: machineA.db, mcp: mcpA, serverId: "server-race-a" }
    const b = { db: machineB.db, mcp: mcpB, serverId: "server-race-b" }
    const docsA = await mcpA.create({
      authType: "bearer",
      bearerToken: "token",
      enabled: true,
      name: "Docs",
      transport: "http",
      url: "https://docs.example.com/mcp"
    })
    const published = await reconcileMcps(a)
    await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, published.changedEntries))
    await reconcileMcps(b)

    await mcpA.remove(docsA.id)
    const removed = await reconcileMcps(a)
    await run(machineB.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, removed.changedEntries))
    let secretReads = 0
    const editedMidPass = {
      ...b,
      mcp: {
        ...mcpB,
        staticSecrets: async (id: string) => {
          const secrets = await mcpB.staticSecrets(id)
          secretReads += 1
          if (secretReads === 1) await mcpB.update(id, { bearerToken: "edited" })
          return secrets
        }
      }
    }
    const kept = await reconcileMcps(editedMidPass)
    expect(kept.status.removed).toEqual([])
    const docsB = (await mcpB.list()).find((server) => server.name === "Docs")
    expect((await mcpB.staticSecrets(docsB?.id ?? "")).bearerToken).toBe("edited")
    expect((await reconcileMcps(b)).status.published).toEqual(["Docs"])
  })

  it("publishes a machine readiness entry once per change, keyed by machine", async () => {
    const { services } = await makeServices("server-p")
    const deps = {
      db: services.db,
      namespace: "test-readiness",
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
    expect((await publishMachineReadiness(deps)).changedEntries).toEqual([])
    const signIn = {
      key: 'provider:["pi","default","anthropic"]',
      value: {},
      timestamp: { wallMs: 12_000, counter: 4, deviceId: "server-q" }
    }
    const answered = await publishMachineReadiness({ ...deps, answers: [signIn] })
    expect(answered.changedEntries.map((entry) => entry.timestamp)).toEqual([
      { wallMs: 12_000, counter: 5, deviceId: "server-p" }
    ])

    const document = await run(services.db.getSyncEntries("test-readiness"))
    expect(document[0]?.key).toBe("server-p")
    const value = Schema.decodeUnknownSync(
      Schema.Struct({
        plugins: Schema.Array(
          Schema.Struct({ id: Schema.String, reason: Schema.optional(Schema.String) })
        )
      })
    )(document[0]?.value)
    expect(value.plugins.map((row) => row.id)).toEqual(["dev-linked", "ffmpeg-tools", "scratchpad"])
    expect(value.plugins[1]?.reason).toBe("needs ffmpeg")

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

    expect((await publishAccountsRoster(deps)).changedEntries).toEqual([])

    const document = await run(services.db.getSyncEntries(ACCOUNTS_SYNC_NAMESPACE))
    expect(document[0]?.key).toBe("server-d")
    const roster = Schema.decodeUnknownSync(
      Schema.Struct({
        accounts: Schema.Array(
          Schema.Struct({ label: Schema.String, email: Schema.optional(Schema.String) })
        )
      })
    )(document[0]?.value)
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

      await services.mcp.create({ ...base, name: "GitHub", url: "https://local.example/mcp" })
      await services.mcp.create({ ...base, name: "GitHub-3", url: "https://decoy.example/mcp" })
      await services.mcp.create({ ...base, name: "Same", url: "https://same.example/mcp" })
      await services.mcp.create({ ...base, name: "Ghost", url: "https://ghost.example/mcp" })
      await run(
        services.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
          {
            key: "GitHub",
            value: mcpValue("GitHub", "https://fleet.example/mcp"),
            timestamp: elsewhereAt(10)
          },
          {
            key: "GitHub-2",
            value: mcpValue("GitHub-2", "https://fleet2.example/mcp"),
            timestamp: elsewhereAt(11)
          },
          {
            key: "Same",
            value: mcpValue("Same", "https://same.example/mcp"),
            timestamp: elsewhereAt(12)
          },
          { key: "Ghost", value: null, deleted: true, timestamp: elsewhereAt(13) }
        ])
      )

      const result = await reconcileMcps(deps)

      expect(result.status.renamed).toEqual([{ from: "GitHub", to: "GitHub-4" }])
      expect([...result.status.published].toSorted()).toEqual(["Ghost", "GitHub-3", "GitHub-4"])
      expect([...result.status.applied].toSorted()).toEqual(["GitHub", "GitHub-2"])
      const list = await services.mcp.list()
      expect(list.find((s) => s.name === "GitHub-4")?.url).toBe("https://local.example/mcp")
      expect(list.find((s) => s.name === "GitHub")?.url).toBe("https://fleet.example/mcp")
      expect(list.find((s) => s.name === "GitHub-2")?.url).toBe("https://fleet2.example/mcp")
      expect(list.filter((s) => s.name === "Same")).toHaveLength(1)
    }
  )
})
