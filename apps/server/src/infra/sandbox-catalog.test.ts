import type { SandboxProfile } from "@codevisor/api"
import {
  fakeDefinition,
  machineField,
  makeFakeSandboxProvider,
  type SandboxAdapter,
  type SandboxProviderDefinition
} from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { HttpFailure, run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import {
  createAccount,
  createProfile,
  deleteAccount,
  deleteProfile,
  hostCapabilities,
  listAccounts,
  profileAvailability,
  updateAccount,
  updateProfile,
  type SandboxCatalogDeps
} from "./sandbox-catalog.js"
import { makeSandboxAdapters, makeSandboxConnections } from "./sandbox-connections.js"
import { connectionOf, profileRecordFields } from "./sandbox-profile-record.js"
import { makeSandboxSettings, SANDBOX_PROFILES_NAMESPACE } from "./sandbox-settings.js"

const stamp = { wallMs: 1, counter: 0, deviceId: "server-a" }

const hostDefinition: SandboxProviderDefinition = {
  ...fakeDefinition("tart", "darwin"),
  displayName: "Host",
  accountFields: [],
  profileFields: [
    machineField("machineId", "Mac", "tart"),
    { key: "spare", label: "Spare", type: "machine", required: false }
  ]
}

const adapterFor = (
  definition: SandboxProviderDefinition,
  extra: Partial<SandboxAdapter> = {}
): SandboxAdapter => ({
  definition,
  connect: () => ({ ...makeFakeSandboxProvider(), definition }),
  ...extra
})

const catalogWith = async (
  adapters: ReadonlyArray<SandboxAdapter>,
  runsHere: (id: string) => boolean = () => true,
  sandboxesUsing = 0
): Promise<SandboxCatalogDeps> => {
  const { services } = await makeServices("server-a")
  const settings = makeSandboxSettings(services.db, "server-a", () => 10)
  const registry = makeSandboxAdapters(adapters, runsHere)
  let ids = 0
  return {
    settings,
    adapters: registry,
    connections: makeSandboxConnections(registry, settings),
    serverId: "server-a",
    sandboxesUsing: () => Promise.resolve(sandboxesUsing),
    newId: () => `id-${(ids += 1)}`,
    now: () => 10
  }
}

const failure = (promise: Promise<unknown>) => promise.catch((cause: unknown) => cause)

const profile = (overrides: Partial<SandboxProfile>): SandboxProfile => ({
  id: "p",
  name: "Profile",
  provider: "e2b",
  values: {},
  createdAt: "2026-10-01T00:00:00.000Z",
  ...overrides
})

describe("sandbox accounts", () => {
  it("saves an account with no label or identity when the provider doesn't report one", async () => {
    const deps = await catalogWith([adapterFor(fakeDefinition())])

    const { account } = await createAccount(deps, { provider: "e2b", values: { apiKey: "k" } })

    expect(account).toEqual({
      id: "id-1",
      provider: "e2b",
      values: {},
      secretsSet: ["apiKey"],
      createdAt: "1970-01-01T00:00:00.010Z"
    })
  })

  it("passes on whatever the provider says when it turns credentials down", async () => {
    const deps = await catalogWith([
      adapterFor(fakeDefinition(), { verify: () => Promise.reject(new Error("bad key")) }),
      adapterFor(fakeDefinition("modal"), { verify: () => Promise.reject("expired") })
    ])

    const failures = await Promise.all([
      failure(createAccount(deps, { provider: "e2b", values: { apiKey: "k" } })),
      failure(createAccount(deps, { provider: "modal", values: { apiKey: "k" } }))
    ])

    expect(failures).toEqual([
      new HttpFailure(400, "Fake didn't accept these credentials: bad key"),
      new HttpFailure(400, "Fake didn't accept these credentials: expired")
    ])
  })

  it("refuses accounts for providers that don't use them, unknown accounts and provider moves", async () => {
    const deps = await catalogWith([adapterFor(fakeDefinition()), adapterFor(hostDefinition)])
    await createAccount(deps, { provider: "e2b", values: { apiKey: "k" } })

    const failures = await Promise.all([
      failure(createAccount(deps, { provider: "tart", values: {} })),
      failure(updateAccount(deps, "missing", { provider: "e2b", values: {} })),
      failure(updateAccount(deps, "id-1", { provider: "tart", values: {} })),
      failure(createAccount(deps, { provider: "vercel", values: {} }))
    ])

    expect(failures).toEqual([
      new HttpFailure(400, "Host doesn't use providers"),
      new HttpFailure(404, "No sandbox provider missing"),
      new HttpFailure(400, "A provider can't move to another vendor"),
      new HttpFailure(404, "No sandbox vendor vercel")
    ])
  })

  it("names every profile and counts every sandbox that still uses an account", async () => {
    const deps = await catalogWith([adapterFor(fakeDefinition())], () => true, 2)
    await createAccount(deps, { provider: "e2b", values: { apiKey: "k" } })
    const values = { name: "A", provider: "e2b" as const, accountId: "id-1", values: {} }
    await createProfile(deps, values)
    await createProfile(deps, { ...values, name: "B" })

    const inUse = await failure(deleteAccount(deps, "id-1"))
    await deleteProfile(deps, "id-2")
    await deleteProfile(deps, "id-3")
    const running = await failure(deleteAccount(deps, "id-1"))

    expect(inUse).toEqual(
      new HttpFailure(409, "A, B use this provider; change or delete those profiles first")
    )
    expect(running).toEqual(new HttpFailure(409, "2 sandboxes are still running on this provider"))
  })

  it("hides accounts whose provider this version doesn't know", async () => {
    const deps = await catalogWith([adapterFor(fakeDefinition())])
    await deps.settings.putAccount({
      id: "old",
      provider: "daytona",
      values: {},
      createdAt: "2026-10-01T00:00:00.000Z"
    })

    expect(await listAccounts(deps)).toEqual([])
  })
})

describe("sandbox profiles", () => {
  it("drops the account for providers that don't use one and checks it for those that do", async () => {
    const deps = await catalogWith([adapterFor(fakeDefinition()), adapterFor(hostDefinition)])
    await createAccount(deps, { provider: "e2b", values: { apiKey: "k" } })
    await deps.settings.putAccount({
      id: "other",
      provider: "tart",
      values: {},
      createdAt: "2026-10-01T00:00:00.000Z"
    })
    const host = {
      name: "Studio",
      provider: "tart" as const,
      accountId: "id-1",
      values: { machineId: "server-a" }
    }

    const { profile: created } = await createProfile(deps, host)
    const failures = await Promise.all([
      failure(createProfile(deps, { name: "E", provider: "e2b", values: {} })),
      failure(createProfile(deps, { name: "E", provider: "e2b", accountId: "other", values: {} })),
      failure(updateProfile(deps, "missing", host)),
      failure(deleteProfile(deps, "missing"))
    ])

    expect(created).toMatchObject({
      id: "id-2",
      provider: "tart",
      values: { machineId: "server-a" }
    })
    expect(created.accountId).toBeUndefined()
    expect(failures).toEqual([
      new HttpFailure(400, "Choose a Fake provider"),
      new HttpFailure(400, "Choose a Fake provider"),
      new HttpFailure(404, "No sandbox profile missing"),
      new HttpFailure(404, "No sandbox profile missing")
    ])
  })

  it("reports what stops a profile here, and lets failed checks through", async () => {
    const throwing = adapterFor(fakeDefinition("modal"), {
      connect: () => ({
        ...makeFakeSandboxProvider(),
        availability: () => Promise.reject(new Error("timed out"))
      })
    })
    const deps = await catalogWith(
      [adapterFor(fakeDefinition()), adapterFor(hostDefinition), throwing],
      (id) => id !== "e2b"
    )
    await deps.settings.putProfile(profile({ id: "a", accountId: "x" }))
    await deps.settings.putProfile(profile({ id: "b", provider: "tart", values: {} }))
    await deps.settings.putProfile(profile({ id: "c", provider: "modal" }))
    await deps.settings.putAccount({
      id: "m",
      provider: "modal",
      values: {},
      createdAt: "2026-10-01T00:00:00.000Z"
    })
    await deps.settings.putProfile(profile({ id: "d", provider: "modal", accountId: "m" }))

    expect(await profileAvailability(deps)).toEqual([
      { profileId: "a", disabledReason: "Fake isn't installed here" },
      { profileId: "b" },
      { profileId: "c", disabledReason: "Its Fake provider was removed" },
      { profileId: "d" }
    ])
    expect(hostCapabilities(deps.adapters)).toEqual(["tart"])
    expect(await deps.connections.all()).toEqual([
      { provider: "tart" },
      { provider: "modal", accountId: "m" }
    ])
  })
})

describe("providers that live on a Mac", () => {
  it("place profiles on their provider's Mac, sweep that vendor once, and need a provider", async () => {
    const macs: SandboxProviderDefinition = {
      ...fakeDefinition("tart", "darwin"),
      displayName: "Mac",
      accountFields: [machineField("machineId", "Mac", "tart")],
      profileFields: []
    }
    const deps = await catalogWith([adapterFor(macs)])
    await createAccount(deps, { provider: "tart", values: { machineId: "server-a" } })
    await createAccount(deps, { provider: "tart", values: { machineId: "server-b" } })
    await deps.settings.putProfile(profile({ id: "here", provider: "tart", accountId: "id-1" }))
    await deps.settings.putProfile(profile({ id: "there", provider: "tart", accountId: "id-2" }))
    await deps.settings.putProfile(
      profile({ id: "older", provider: "tart", values: { machineId: "server-b" } })
    )

    const withoutProvider = await failure(
      createProfile(deps, { name: "Nowhere", provider: "tart", values: {} })
    )

    expect(await profileAvailability(deps)).toEqual([
      { profileId: "here" },
      { profileId: "older", disabledReason: "Runs on another Mac" },
      { profileId: "there", disabledReason: "Runs on another Mac" }
    ])
    expect(hostCapabilities(deps.adapters)).toEqual(["tart"])
    expect(await deps.connections.all()).toEqual([{ provider: "tart" }])
    expect(withoutProvider).toEqual(new HttpFailure(400, "Choose a Mac provider"))
  })
})

describe("sandbox connections", () => {
  it("connect without an account where none is needed, and need one everywhere else", async () => {
    const deps = await catalogWith(
      [adapterFor(fakeDefinition()), adapterFor(hostDefinition)],
      (id) => id !== "tart"
    )
    await createAccount(deps, { provider: "e2b", values: { apiKey: "k" } })
    await deps.settings.putAccount({
      id: "old",
      provider: "daytona",
      values: {},
      createdAt: "2026-10-01T00:00:00.000Z"
    })

    const host = await deps.connections.connect({ provider: "tart" })
    const failures = await Promise.all([
      failure(deps.connections.connect({ provider: "e2b" })),
      failure(deps.connections.connect({ provider: "e2b", accountId: "gone" }))
    ])

    expect(host.definition.id).toBe("tart")
    expect(failures).toEqual([
      new HttpFailure(409, "Its Fake provider was removed"),
      new HttpFailure(409, "Its Fake provider was removed")
    ])
    expect(await deps.connections.all()).toEqual([{ provider: "e2b", accountId: "id-1" }])
  })

  it("link a record to its profile with or without an account", () => {
    const accountless = profile({ provider: "tart" })

    expect(profileRecordFields(accountless)).toEqual({
      provider: "tart",
      profileId: "p",
      profileName: "Profile"
    })
    expect(connectionOf(accountless)).toEqual({ provider: "tart" })
  })
})

describe("sandbox settings", () => {
  it("skips entries it can't read", async () => {
    const { services } = await makeServices("server-a")
    const settings = makeSandboxSettings(services.db, "server-a")
    await run(
      services.db.mergeSyncEntries(SANDBOX_PROFILES_NAMESPACE, [
        { key: "broken", value: { name: 3 }, timestamp: stamp }
      ])
    )

    expect(await settings.profiles()).toEqual([])
  })
})
