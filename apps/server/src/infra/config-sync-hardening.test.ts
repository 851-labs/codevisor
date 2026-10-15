import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import { field } from "../unknown-values.js"
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

const oauthMaterial = (token: string, savedAt: number) =>
  JSON.stringify({
    tokens: { access_token: token, refresh_token: `r-${token}`, token_type: "bearer" },
    tokensSavedAt: savedAt
  })

const scopedEnvelopeOwner = async (machine: Machine) => {
  const entries = await run(machine.db.getSyncEntries(MCPS_SYNC_NAMESPACE))
  const scoped = entries.find((entry) => entry.key === "Scoped")
  return field(field(scoped?.value, "oauth"), "owner")
}

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
    "simultaneous OAuth ownership claims resolve to one stable owner",
    { timeout: 30_000 },
    async () => {
      const a = await makeMachine("hard-oauth-a", 3_000_000)
      const b = await makeMachine("hard-oauth-b", 3_000_100)

      await a.mcp.create({
        authType: "oauth",
        enabled: true,
        name: "Scoped",
        transport: "http",
        url: "https://oauth.example/mcp"
      })
      const seeded = await reconcileMcps(a)
      await gossip(seeded, b)
      await reconcileMcps(b)

      await a.mcp.importOAuthMaterial((await serverNamed(a, "Scoped")).id, {
        owner: "hard-oauth-a",
        material: oauthMaterial("at-a", 1_000)
      })
      await b.mcp.importOAuthMaterial((await serverNamed(b, "Scoped")).id, {
        owner: "hard-oauth-b",
        material: oauthMaterial("at-b", 2_000)
      })
      const claimA = await reconcileMcps(a)
      const claimB = await reconcileMcps(b)
      expect(claimA.status.published).toEqual(["Scoped"])
      expect(claimB.status.published).toEqual(["Scoped"])

      await gossip(claimB, a)
      await gossip(claimA, b)
      await reconcileMcps(a)
      await reconcileMcps(b)

      const ownerOnA = await scopedEnvelopeOwner(a)
      const ownerOnB = await scopedEnvelopeOwner(b)
      expect(ownerOnA).toBe(ownerOnB)
      expect(["hard-oauth-a", "hard-oauth-b"]).toContain(ownerOnA)
      const stateA = await a.mcp.oauthSyncState((await serverNamed(a, "Scoped")).id)
      const stateB = await b.mcp.oauthSyncState((await serverNamed(b, "Scoped")).id)
      expect(stateA?.owner).toBe(ownerOnA)
      expect(stateB?.owner).toBe(ownerOnA)
      expect(stateA?.material).toBe(stateB?.material)
      const winningToken = ownerOnA === "hard-oauth-a" ? "at-a" : "at-b"
      expect(stateA?.material).toContain(winningToken)

      for (const machine of [a, b]) {
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
        expect((await reconcileMcps(machine)).changedEntries).toEqual([])
      }
    }
  )
})
