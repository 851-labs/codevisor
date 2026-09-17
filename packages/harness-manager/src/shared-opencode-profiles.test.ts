import { mkdtemp, readFile, writeFile, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { Effect } from "effect"
import { afterEach, expect, it } from "vitest"

import {
  reconcileSharedOpenCodeProfiles,
  sharedProfileCredentialSource
} from "./shared-opencode-profiles.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)
const cleanups: Array<() => Promise<void>> = []
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup()
})
const id = "shared-00000000-0000-0000-0000-000000000001"
const document = (label = "Work", activeProfileId = "default") =>
  JSON.stringify({ profiles: [{ id, label }], activeProfileId })
const fixture = async () => {
  const dataDir = await mkdtemp(join(tmpdir(), "codevisor-shared-profiles-"))
  cleanups.push(() => rm(dataDir, { recursive: true, force: true }))
  const db = await run(makeDatabase({ filename: join(dataDir, "db.sqlite"), serverId: "test" }))
  cleanups.push(() => run(db.close))
  const deps = { dataDir, db, removeAccount: (id: string) => run(db.removeHarnessAccount(id)) }
  return {
    ...deps,
    reconcile: (content?: string) => reconcileSharedOpenCodeProfiles(deps, content)
  }
}

it("creates shared profiles, applies labels and selections, and removes only shared profiles", async () => {
  const f = await fixture()
  const sources = await f.reconcile(document())
  expect(sources.map((source) => source.id)).toEqual([`opencode-profile:${id}`])
  expect((await run(f.db.getHarnessAccount(id)))?.label).toBe("Work")
  await f.reconcile(document("Team", id))
  expect(await run(f.db.getHarnessAccount(id))).toMatchObject({ label: "Team", isActive: true })
  await f.reconcile(document("Team", id))
  await saveLocal(f.db, "local")
  await f.reconcile()
  expect(await run(f.db.getHarnessAccount(id))).toBeUndefined()
  expect(await run(f.db.listHarnessAccounts("opencode"))).toHaveLength(2)
  expect(
    (await run(f.db.listHarnessAccounts("opencode"))).find((a) => a.isActive)?.profileKind
  ).toBe("default")
})

const saveLocal = (
  db: CodevisorDatabaseService,
  accountId: string,
  harnessId = "opencode",
  profileKey = accountId,
  profileKind: "managed" | "default" = "managed"
) =>
  run(
    db.saveHarnessAccount({
      id: accountId,
      harnessId,
      profileKey,
      profileKind,
      label: "Local",
      authState: "unauthenticated",
      canLogin: true,
      canLogout: false
    })
  )

it("keeps machine labels, profile removals and account selections local", async () => {
  const f = await fixture()
  await f.reconcile(document())
  await run(f.db.updateHarnessAccountAuth(id, { label: "Personal", authState: "unauthenticated" }))
  await saveLocal(f.db, "local")
  await run(f.db.setActiveHarnessAccount("opencode", "local"))
  await f.reconcile(document("Team", id))
  expect((await run(f.db.getHarnessAccount(id)))?.label).toBe("Personal")
  expect((await run(f.db.getHarnessAccount("local")))?.isActive).toBe(true)
  await run(f.db.removeHarnessAccount(id))
  expect(await f.reconcile(document())).toEqual([])
  expect(await run(f.db.getHarnessAccount(id))).toBeUndefined()
  await f.reconcile()
})

it("adopts an existing shared profile after interruption and respects an initial local selection", async () => {
  const f = await fixture()
  await saveLocal(f.db, id)
  await saveLocal(f.db, "local")
  await run(f.db.setActiveHarnessAccount("opencode", "local"))
  await f.reconcile(document())
  expect((await run(f.db.getHarnessAccount(id)))?.label).toBe("Work")
  expect((await run(f.db.getHarnessAccount("local")))?.isActive).toBe(true)
})

it("keeps a locally selected shared profile when a different global selection changes", async () => {
  const f = await fixture()
  await f.reconcile(document())
  await run(f.db.setActiveHarnessAccount("opencode", id))
  await f.reconcile(document("Team"))
  expect((await run(f.db.getHarnessAccount(id)))?.isActive).toBe(true)
})

it("rejects malformed and duplicate profile IDs before touching account state", async () => {
  const f = await fixture()
  for (const value of [
    1,
    null,
    {},
    { profiles: 1 },
    { profiles: [] },
    { profiles: [null], activeProfileId: "default" },
    { profiles: [1], activeProfileId: "default" },
    ...[
      { id: 1, label: "A" },
      { id: "../../outside", label: "A" },
      { id, label: 1 },
      { id, label: " " }
    ].map((profile) => ({ profiles: [profile], activeProfileId: "default" })),
    {
      profiles: [
        { id, label: "A" },
        { id, label: "B" }
      ],
      activeProfileId: "default"
    },
    { profiles: [], activeProfileId: "missing" }
  ]) {
    await expect(f.reconcile(JSON.stringify(value))).rejects.toThrow("Invalid shared OpenCode")
  }
  expect(await run(f.db.listHarnessAccounts("opencode"))).toEqual([])
})

it.each(["harness", "kind", "key"])("does not overwrite an account collision: %s", async (kind) => {
  const f = await fixture()
  await saveLocal(
    f.db,
    id,
    kind === "harness" ? "codex" : "opencode",
    kind === "key" ? "other" : id,
    kind === "kind" ? "default" : "managed"
  )
  await expect(f.reconcile(document())).rejects.toThrow("conflicts")
})

it("retries profile deletion failures without forgetting ownership", async () => {
  const f = await fixture()
  await f.reconcile(document())
  await expect(
    reconcileSharedOpenCodeProfiles({
      ...f,
      removeAccount: async () => {
        throw new Error("Profile in use")
      }
    })
  ).rejects.toThrow("Profile in use")
  await f.reconcile()
  expect(await run(f.db.getHarnessAccount(id))).toBeUndefined()
})

it("applies shared keys without publishing or replacing local credentials and removals", async () => {
  const f = await fixture()
  const source = sharedProfileCredentialSource(id, f.dataDir)
  const path = join(f.dataDir, "data", "opencode", "auth.json")
  const key = (key: string) => ({ type: "api", key })
  expect(await source.read()).toBeUndefined()
  expect(source.tombstoneOnAbsence).toBe(false)
  await source.apply(JSON.stringify({ openai: key("one"), google: key("one"), groq: key("one") }))
  const current = JSON.parse(await readFile(path, "utf8"))
  delete current.google
  current.openai = key("local")
  current.anthropic = { type: "oauth", access: "machine-only" }
  await writeFile(path, JSON.stringify(current))
  await source.apply(
    JSON.stringify({
      openai: key("two"),
      google: key("two"),
      anthropic: key("two"),
      groq: key("two"),
      openrouter: key("two")
    })
  )
  expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
    openai: key("local"),
    anthropic: current.anthropic,
    groq: key("two"),
    openrouter: key("two")
  })
  await source.apply("{}")
  expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
    openai: key("local"),
    anthropic: current.anthropic
  })
  expect(await source.read()).toBeUndefined()
  // Reconstructing the source simulates a restart; the local override survives.
  await sharedProfileCredentialSource(id, f.dataDir).apply(JSON.stringify({ openai: key("three") }))
  expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
    openai: key("local"),
    anthropic: current.anthropic
  })
})

it("rejects rotating credentials and malformed shared documents", async () => {
  const f = await fixture()
  const source = sharedProfileCredentialSource(id, f.dataDir)
  for (const content of [
    "null",
    "[]",
    "1",
    '{"x":1}',
    '{"x":null}',
    '{"x":{}}',
    '{"x":{"type":"oauth"}}'
  ])
    await expect(source.apply(content)).rejects.toThrow("static provider credentials")
  await source.apply('{"x":{"type":"wellknown","token":"static"}}')
})
