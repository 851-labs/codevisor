import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import { field, isRecord } from "../unknown-values.js"
import { MCPS_SYNC_NAMESPACE, reconcileMcps } from "./config-sync.js"

const makeMachine = async (serverId: string, nowMs: number) => {
  const { services } = await makeServices(serverId)
  if (services.mcp === undefined) throw new Error("mcp unavailable")
  return {
    db: services.db,
    mcp: services.mcp,
    serverId,
    now: () => nowMs
  }
}

type Machine = Awaited<ReturnType<typeof makeMachine>>

const gossip = async (from: { changedEntries: ReadonlyArray<SyncEntryRecord> }, to: Machine) => {
  await run(to.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, from.changedEntries))
}

const serverNamed = async (machine: Machine, name: string) => {
  const found = (await machine.mcp.list()).find((server) => server.name === name)
  if (found === undefined) throw new Error(`${name} missing on ${machine.serverId}`)
  return found
}

const credentialReference = (seed: string) => ({
  id: `credential-${seed}-0123456789`,
  key: seed.repeat(43)
})

const scopedEntryValue = async (machine: Machine) =>
  (await run(machine.db.getSyncEntries(MCPS_SYNC_NAMESPACE))).find(
    (entry) => entry.key === "Scoped"
  )?.value

describe("config sync hardening", () => {
  it(
    "three machines racing edits on skewed clocks converge without oscillating",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("hard-a", 1_000_000)
      const b = await makeMachine("hard-b", 1_000_500)
      const c = await makeMachine("hard-c", 500)

      await a.mcp.create({
        authType: "none",
        enabled: true,
        name: "Fleet",
        transport: "http",
        url: "https://v1.example/mcp"
      })
      const seeded = await reconcileMcps(a)
      await gossip(seeded, b)
      await gossip(seeded, c)
      await reconcileMcps(b)
      await reconcileMcps(c)

      await a.mcp.update((await serverNamed(a, "Fleet")).id, { url: "https://a.example/mcp" })
      await b.mcp.update((await serverNamed(b, "Fleet")).id, { url: "https://b.example/mcp" })
      await c.mcp.update((await serverNamed(c, "Fleet")).id, { url: "https://c.example/mcp" })
      const editA = await reconcileMcps(a)
      const editB = await reconcileMcps(b)
      const editC = await reconcileMcps(c)
      expect(editA.status.published).toEqual(["Fleet"])
      expect(editB.status.published).toEqual(["Fleet"])
      expect(editC.status.published).toEqual(["Fleet"])

      await gossip(editC, a)
      await gossip(editB, a)
      await gossip(editA, b)
      await gossip(editC, b)
      await gossip(editB, c)
      await gossip(editA, c)
      await reconcileMcps(a)
      await reconcileMcps(b)
      await reconcileMcps(c)

      for (const machine of [a, b, c]) {
        expect((await serverNamed(machine, "Fleet")).url).toBe("https://b.example/mcp")
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
      }

      await c.mcp.update((await serverNamed(c, "Fleet")).id, { url: "https://c2.example/mcp" })
      const lateC = await reconcileMcps(c)
      expect(lateC.status.published).toEqual(["Fleet"])
      await gossip(lateC, a)
      await gossip(lateC, b)
      await reconcileMcps(a)
      await reconcileMcps(b)
      expect((await serverNamed(a, "Fleet")).url).toBe("https://c2.example/mcp")
      expect((await serverNamed(b, "Fleet")).url).toBe("https://c2.example/mcp")
    }
  )

  it(
    "stale replays never resurrect a deletion; a deliberate re-add does",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("hard-res-a", 2_000_000)
      const b = await makeMachine("hard-res-b", 2_000_100)

      await a.mcp.create({
        authType: "none",
        enabled: true,
        name: "Doomed",
        transport: "http",
        url: "https://doomed.example/mcp"
      })
      const seeded = await reconcileMcps(a)
      await gossip(seeded, b)
      await reconcileMcps(b)

      await a.mcp.remove((await serverNamed(a, "Doomed")).id)
      const deleted = await reconcileMcps(a)
      await gossip(deleted, b)
      expect((await reconcileMcps(b)).status.removed).toEqual(["Doomed"])
      expect((await b.mcp.list()).some((server) => server.name === "Doomed")).toBe(false)

      await gossip(seeded, b)
      const afterReplay = await reconcileMcps(b)
      expect(afterReplay.status).toEqual({ published: [], applied: [], removed: [], renamed: [] })
      expect((await b.mcp.list()).some((server) => server.name === "Doomed")).toBe(false)
      await gossip(seeded, a)
      expect((await reconcileMcps(a)).changedEntries).toEqual([])
      expect((await a.mcp.list()).some((server) => server.name === "Doomed")).toBe(false)

      await a.mcp.create({
        authType: "none",
        enabled: true,
        name: "Doomed",
        transport: "http",
        url: "https://reborn.example/mcp"
      })
      const readded = await reconcileMcps(a)
      expect(readded.status.published).toEqual(["Doomed"])
      await gossip(readded, b)
      expect((await reconcileMcps(b)).status.applied).toEqual(["Doomed"])
      expect((await serverNamed(b, "Doomed")).url).toBe("https://reborn.example/mcp")
    }
  )

  it(
    "removes OAuth copies that hold a sign-in, and stale replays don't bring them back",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("oauth-res-a", 6_000_000)
      const b = await makeMachine("oauth-res-b", 6_000_100)
      for (const name of ["Signed In", "Signed Out"]) {
        await b.mcp.create({
          authType: "oauth",
          enabled: true,
          name,
          transport: "http",
          url: `https://${name === "Signed In" ? "in" : "out"}.example/mcp`
        })
        await b.mcp.setOAuthCredential((await serverNamed(b, name)).id, credentialReference("b"))
      }
      await b.mcp.setOAuthCredential((await serverNamed(b, "Signed Out")).id, null)
      const seeded = await reconcileMcps(b)
      await gossip(seeded, a)
      expect([...(await reconcileMcps(a)).status.applied].toSorted()).toEqual([
        "Signed In",
        "Signed Out"
      ])

      await a.mcp.remove((await serverNamed(a, "Signed In")).id)
      await a.mcp.remove((await serverNamed(a, "Signed Out")).id)
      const deleted = await reconcileMcps(a)
      await gossip(deleted, b)
      expect([...(await reconcileMcps(b)).status.removed].toSorted()).toEqual([
        "Signed In",
        "Signed Out"
      ])

      await gossip(seeded, a)
      await gossip(seeded, b)
      for (const machine of [a, b]) {
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
        const names = (await machine.mcp.list()).map((server) => server.name)
        expect(names).not.toContain("Signed In")
        expect(names).not.toContain("Signed Out")
      }
    }
  )

  it(
    "keeps a synced sign-in when an older machine writes the entry without one",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("keep-oauth-a", 4_000_000)
      const b = await makeMachine("keep-oauth-b", 4_000_100)
      await a.mcp.create({
        authType: "oauth",
        enabled: false,
        name: "Scoped",
        transport: "http",
        url: "https://oauth.example/mcp"
      })
      const signedIn = credentialReference("a")
      await a.mcp.setOAuthCredential((await serverNamed(a, "Scoped")).id, signedIn)
      const published = await reconcileMcps(a)
      const publishedValue = published.changedEntries.find((entry) => entry.key === "Scoped")?.value
      if (!isRecord(publishedValue)) throw new Error("Scoped was not published")
      const { oauthCredential: _credential, ...withoutCredential } = publishedValue
      await run(
        a.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
          {
            key: "Scoped",
            value: { ...withoutCredential, enabled: true },
            timestamp: { wallMs: 9_000_000, counter: 0, deviceId: "older-build" }
          }
        ])
      )

      const repaired = await reconcileMcps(a)
      expect(repaired.status.applied).toEqual(["Scoped"])
      expect(repaired.status.published).toEqual(["Scoped"])
      expect((await serverNamed(a, "Scoped")).enabled).toBe(true)
      expect(await a.mcp.oauthCredential((await serverNamed(a, "Scoped")).id)).toEqual(signedIn)
      await gossip(repaired, b)
      await reconcileMcps(b)
      expect(await b.mcp.oauthCredential((await serverNamed(b, "Scoped")).id)).toEqual(signedIn)
      expect((await reconcileMcps(a)).changedEntries).toEqual([])
      expect((await reconcileMcps(b)).changedEntries).toEqual([])
    }
  )

  it(
    "keeps an older machine's own sign-in field intact so it does not republish during a rollout",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("rollout-new", 5_000_000)
      await a.mcp.create({
        authType: "oauth",
        enabled: false,
        name: "Scoped",
        transport: "http",
        url: "https://oauth.example/mcp"
      })
      const signedIn = credentialReference("a")
      await a.mcp.setOAuthCredential((await serverNamed(a, "Scoped")).id, signedIn)
      const published = await reconcileMcps(a)
      const publishedValue = published.changedEntries.find((entry) => entry.key === "Scoped")?.value
      if (!isRecord(publishedValue)) throw new Error("Scoped was not published")
      const { oauthCredential: _credential, ...config } = publishedValue
      const legacyEnvelope = { owner: "old-owner", rotatedAtMs: 7, material: "{}" }
      const fromOldOwner = { ...config, oauth: legacyEnvelope }
      await run(
        a.db.mergeSyncEntries(MCPS_SYNC_NAMESPACE, [
          {
            key: "Scoped",
            value: fromOldOwner,
            timestamp: { wallMs: 9_000_000, counter: 0, deviceId: "old-build" }
          }
        ])
      )

      const repaired = await reconcileMcps(a)
      expect(repaired.status.published).toEqual(["Scoped"])
      expect(await scopedEntryValue(a)).toEqual({ ...fromOldOwner, oauthCredential: signedIn })
      expect((await reconcileMcps(a)).changedEntries).toEqual([])

      await a.mcp.update((await serverNamed(a, "Scoped")).id, { enabled: true })
      await reconcileMcps(a)
      expect(await scopedEntryValue(a)).toEqual({
        ...fromOldOwner,
        enabled: true,
        oauthCredential: signedIn
      })
    }
  )

  it(
    "simultaneous sign-ins on two machines converge on one credential",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("hard-oauth-a", 3_000_000)
      const b = await makeMachine("hard-oauth-b", 3_000_100)

      await a.mcp.create({
        authType: "oauth",
        enabled: false,
        name: "Scoped",
        transport: "http",
        url: "https://oauth.example/mcp"
      })
      const seeded = await reconcileMcps(a)
      await gossip(seeded, b)
      await reconcileMcps(b)

      await a.mcp.setOAuthCredential((await serverNamed(a, "Scoped")).id, credentialReference("a"))
      await b.mcp.setOAuthCredential((await serverNamed(b, "Scoped")).id, credentialReference("b"))
      const claimA = await reconcileMcps(a)
      const claimB = await reconcileMcps(b)
      expect(claimA.status.published).toEqual(["Scoped"])
      expect(claimB.status.published).toEqual(["Scoped"])

      await gossip(claimB, a)
      await gossip(claimA, b)
      await reconcileMcps(a)
      await reconcileMcps(b)

      const onA = await a.mcp.oauthCredential((await serverNamed(a, "Scoped")).id)
      const onB = await b.mcp.oauthCredential((await serverNamed(b, "Scoped")).id)
      expect(onA).toEqual(onB)
      expect([credentialReference("a"), credentialReference("b")]).toContainEqual(onA)
      expect(field(await scopedEntryValue(a), "oauthCredential")).toEqual(onA)

      for (const machine of [a, b]) {
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
      }
    }
  )
})
