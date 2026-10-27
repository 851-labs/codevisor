import { machineField } from "@codevisor/sandboxes"
import { afterEach, describe, expect, it, vi } from "vitest"

import type { SandboxEventPublisher } from "../infra/sandbox-local-workspaces.js"
import { FAKE_PROFILE, sandboxHarness } from "../infra/sandbox-test-support.js"
import { jsonRequest, startWithApp } from "../test-support.js"

const secretValue = "e2b_very-secret-value-0123456789"

type HarnessOptions = Parameters<typeof sandboxHarness>[0]

const startSandboxServer = async (options: HarnessOptions = {}) => {
  const harness = await sandboxHarness(options)
  const bound: SandboxEventPublisher[] = []
  const server = await startWithApp({
    ...harness.services,
    sandboxes: {
      sandboxes: harness.machines,
      catalog: harness.catalog,
      bindEvents: (publish) => bound.push(publish)
    }
  })
  return { harness, server, bound }
}

const send = (method: string, body: unknown): RequestInit => ({
  method,
  body: JSON.stringify(body)
})

const account = (values: Record<string, unknown>, label = "Team") => ({
  provider: "e2b",
  label,
  values
})

afterEach(() => {
  vi.restoreAllMocks()
})

describe("sandbox provider accounts", () => {
  it("checks credentials before saving, and never hands the secret back or logs it", async () => {
    const logged: string[] = []
    for (const level of ["log", "error", "warn", "info"] as const) {
      vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
        logged.push(args.map(String).join(" "))
      })
    }
    const checked: unknown[] = []
    const { server } = await startSandboxServer({
      verify: (values) => {
        checked.push(values)
        return Promise.resolve({ identity: "dylan@851.sh" })
      }
    })

    const saved = await jsonRequest(
      server,
      "/v1/sandbox-accounts",
      send("POST", account({ apiKey: ` ${secretValue} ` }, " Work "))
    )
    const listed = await jsonRequest(server, "/v1/sandbox-accounts")

    expect(saved).toMatchObject({
      status: 201,
      body: {
        provider: "e2b",
        label: "Work",
        identity: "dylan@851.sh",
        values: {},
        secretsSet: ["apiKey"]
      }
    })
    expect(listed.body).toMatchObject({
      accounts: [
        { id: "account-1", label: "Team" },
        { label: "Work", secretsSet: ["apiKey"] }
      ]
    })
    expect(checked).toEqual([{ apiKey: secretValue }])
    for (const seen of [saved.body, listed.body, logged]) {
      expect(JSON.stringify(seen)).not.toContain(secretValue)
    }
  })

  it("refuses credentials the provider rejects, and keeps a saved secret an edit leaves blank", async () => {
    const { harness, server } = await startSandboxServer({
      verify: (values) =>
        values["apiKey"] === "wrong"
          ? Promise.reject(new Error("invalid key"))
          : Promise.resolve({})
    })

    const rejected = await jsonRequest(
      server,
      "/v1/sandbox-accounts",
      send("POST", account({ apiKey: "wrong" }))
    )
    const missing = await jsonRequest(server, "/v1/sandbox-accounts", send("POST", account({})))
    const renamed = await jsonRequest(
      server,
      "/v1/sandbox-accounts/account-1",
      send("PUT", account({ apiKey: "" }, "Renamed"))
    )

    expect(rejected).toMatchObject({
      status: 400,
      body: { error: "Fake didn't accept these credentials: invalid key" }
    })
    expect(missing.status).toBe(201)
    expect(renamed).toMatchObject({
      status: 200,
      body: { label: "Renamed", secretsSet: ["apiKey"] }
    })
    expect((await harness.settings.account("account-1"))?.values).toEqual({ apiKey: "e2b_secret" })
  })

  it("won't remove an account that a profile or a running sandbox still uses", async () => {
    const { harness, server } = await startSandboxServer()
    const remove = () => jsonRequest(server, "/v1/sandbox-accounts/account-1", { method: "DELETE" })

    const usedByProfile = await remove()
    await jsonRequest(server, "/v1/sandbox-profiles/profile-1", { method: "DELETE" })
    await harness.records.put({
      id: "running",
      name: "running",
      projectId: "project-1",
      provider: "e2b",
      accountId: "account-1",
      state: "ready",
      createdAt: "2026-10-23T00:00:00.000Z"
    })
    const usedBySandbox = await remove()
    await harness.records.remove("running")
    const removed = await remove()

    expect(usedByProfile).toMatchObject({
      status: 409,
      body: { error: "Ubuntu Sandbox uses this account; change or delete that profile first" }
    })
    expect(usedBySandbox).toMatchObject({
      status: 409,
      body: { error: "A sandbox is still running on this account" }
    })
    expect(removed.status).toBe(204)
    expect(await harness.settings.accounts()).toEqual([])
  })
})

describe("sandbox profiles", () => {
  it("creates, edits and deletes profiles checked against their provider's fields", async () => {
    const { server } = await startSandboxServer()
    const profile = { name: " Big Sandbox ", provider: "e2b", accountId: "account-1", values: {} }

    const created = await jsonRequest(server, "/v1/sandbox-profiles", send("POST", profile))
    const edited = await jsonRequest(
      server,
      "/v1/sandbox-profiles/id-1",
      send("PUT", { ...profile, values: { size: "large" } })
    )
    const failures = await Promise.all(
      [
        { ...profile, name: " " },
        { ...profile, accountId: "nope" },
        { ...profile, values: { size: 3 } }
      ].map(
        async (body) => (await jsonRequest(server, "/v1/sandbox-profiles", send("POST", body))).body
      )
    )
    const deleted = await jsonRequest(server, "/v1/sandbox-profiles/profile-1", {
      method: "DELETE"
    })
    const listed = await jsonRequest(server, "/v1/sandbox-profiles")

    expect(created).toMatchObject({
      status: 201,
      body: { id: "id-1", name: "Big Sandbox", values: { size: "small" } }
    })
    expect(edited).toMatchObject({ status: 200, body: { id: "id-1", values: { size: "large" } } })
    expect(failures).toEqual([
      { error: "Name is required" },
      { error: "Choose a Fake account" },
      { error: "Size must be text" }
    ])
    expect(deleted.status).toBe(204)
    expect(listed.body).toMatchObject({ profiles: [{ id: "id-1", name: "Big Sandbox" }] })
  })

  it("says why this machine can't start a profile right now", async () => {
    const { harness, server } = await startSandboxServer({
      extraProfileFields: [machineField("machineId", "Mac", "tart")],
      availability: () => Promise.resolve("The limit of 2 macOS VMs per Mac has been reached")
    })
    await harness.settings.putProfile({ ...FAKE_PROFILE, id: "orphan", accountId: "gone" })
    await harness.settings.putProfile({
      ...FAKE_PROFILE,
      id: "studio",
      values: { machineId: "server-studio" }
    })
    await harness.settings.putProfile({ ...FAKE_PROFILE, id: "newer", provider: "vercel" })

    const availability = await jsonRequest(server, "/v1/sandbox-profiles/availability")

    expect(availability.body).toEqual({
      profiles: [
        { profileId: "newer", disabledReason: "Update Codevisor to use vercel sandboxes" },
        { profileId: "orphan", disabledReason: "Its Fake account was removed" },
        {
          profileId: "profile-1",
          disabledReason: "The limit of 2 macOS VMs per Mac has been reached"
        },
        { profileId: "studio", disabledReason: "Runs on another Mac" }
      ]
    })
  })

  it("lists each provider's fields and what this machine can host", async () => {
    const { server } = await startSandboxServer({
      extraProfileFields: [machineField("machineId", "Mac", "tart")]
    })

    const providers = await jsonRequest(server, "/v1/sandbox-providers")

    expect(providers.body).toMatchObject({
      providers: [
        {
          id: "e2b",
          displayName: "Fake",
          accountFields: [{ key: "apiKey", type: "secret" }],
          profileFields: [
            { key: "size", default: "small" },
            { key: "machineId", type: "machine" }
          ]
        }
      ],
      capabilities: ["tart"]
    })
  })
})

describe("sandbox routes", () => {
  it("starts sandboxes from a profile, lists and destroys them", async () => {
    const { harness, server } = await startSandboxServer()

    const created = await jsonRequest(
      server,
      "/v1/sandboxes",
      send("POST", { profileId: "profile-1", projectId: "project-1", name: "box" })
    )
    await harness.machines.settled()
    const listed = await jsonRequest(server, "/v1/sandboxes")
    const destroyed = await jsonRequest(server, "/v1/sandboxes/id-1", { method: "DELETE" })

    expect(created).toMatchObject({ status: 202, body: { id: "id-1", state: "creating" } })
    expect(listed.body).toMatchObject([{ id: "id-1", state: "ready", profileId: "profile-1" }])
    expect(destroyed).toEqual({ status: 200, body: { destroyed: "id-1" } })
    expect(harness.provider.machines.size).toBe(0)
  })

  it("hands a sandbox started before the first send to the chat's workspace", async () => {
    const { harness, server } = await startSandboxServer()
    await jsonRequest(
      server,
      "/v1/sandboxes",
      send("POST", { profileId: "profile-1", projectId: "project-1", defersWorkspace: true })
    )
    await harness.machines.settled()

    const claimed = await jsonRequest(
      server,
      "/v1/sandboxes/id-1/workspace",
      send("POST", { workspaceId: "workspace-1" })
    )

    expect(claimed).toMatchObject({ status: 200, body: { id: "id-1", workspaceId: "workspace-1" } })
  })

  it("starts the sandbox again when its archived workspace is unarchived", async () => {
    const { harness, server } = await startSandboxServer()
    await harness.machines.create({ profileId: "profile-1", projectId: "project-1", name: "box" })
    await harness.machines.settled()
    const workspace = harness.workspaces[0]
    if (workspace !== undefined) workspace.isArchived = true
    await harness.machines.watch()

    const unarchived = await jsonRequest(
      server,
      "/v1/workspaces/id-2",
      send("PATCH", { isArchived: false })
    )
    await harness.machines.settled()

    expect(unarchived.status).toBe(200)
    expect(await harness.machines.list()).toMatchObject([{ state: "ready", workspaceId: "id-2" }])
  })

  it("publishes the sandbox's workspace changes as server events once requests arrive", async () => {
    const { server, bound } = await startSandboxServer()
    const before = await jsonRequest(server, "/v1/events/cursor")

    await bound.at(-1)?.("workspace.deleted", "w-1", { id: "w-1" })
    const after = await jsonRequest(server, "/v1/events/cursor")

    expect(bound.length).toBeGreaterThan(0)
    expect(after.body).not.toEqual(before.body)
  })

  it("leaves other methods on sandbox paths to the rest of the router", async () => {
    const { server } = await startSandboxServer()

    expect((await jsonRequest(server, "/v1/sandboxes/id-1", { method: "PATCH" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/sandbox-accounts/a", { method: "PATCH" })).status).toBe(
      404
    )
  })

  it("answers 501 when the server has no sandbox support", async () => {
    const { harness } = await startSandboxServer()
    const bare = await startWithApp(harness.services)

    expect((await jsonRequest(bare, "/v1/sandboxes")).status).toBe(501)
    expect((await jsonRequest(bare, "/v1/sandbox-profiles")).status).toBe(501)
  })
})
