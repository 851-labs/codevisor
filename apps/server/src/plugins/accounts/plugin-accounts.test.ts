import { dirname } from "node:path"

import type { PluginAccountSpec } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { manualOAuthClock, sharedCoordinator } from "../../infra/mcp-oauth-test-support.js"
import { mcpCredentialVault } from "../../infra/shared-account-storage.js"
import { makeServices } from "../../test-support.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { makePluginAccountStore, type PluginAccountRecord } from "./plugin-account-store.js"
import { makePluginAccounts, type PluginVault } from "./plugin-accounts.js"

const tokenSpec: PluginAccountSpec = {
  label: "API token",
  fields: [
    { key: "workspace", label: "Workspace", type: "string", required: true },
    { key: "token", label: "Token", type: "secret", required: true }
  ]
}

const accountsFixture = async (options: { readonly revokeFails?: boolean } = {}) => {
  const { services } = await makeServices("server-a")
  const clock = manualOAuthClock(Date.UTC(2026, 9, 27, 9))
  const realVault = mcpCredentialVault(
    dirname(services.attachments.root),
    sharedCoordinator(clock).machine("server-a"),
    clock.now
  )
  const revoked: Array<string> = []
  const vault: PluginVault = {
    ...realVault,
    revoke: async (reference) => {
      revoked.push(reference.id)
      if (options.revokeFails === true) throw new Error("vault offline")
      await realVault.revoke(reference)
    }
  }
  const server = await savePluginRow(services.db, "Tokens", {
    catalogId: "example.tokens",
    enabled: false
  })
  const store = makePluginAccountStore(services.db, "server-a", clock.now)
  const accounts = makePluginAccounts({
    store,
    vault,
    server: async () => server,
    spec: () => tokenSpec,
    redirects: {
      prepare: async () => ({ redirectUri: "http://127.0.0.1/callback", deviceId: "local" })
    },
    onChanged: () => undefined,
    now: clock.now
  })
  const seed = (record: Partial<PluginAccountRecord> & Pick<PluginAccountRecord, "id">) =>
    store.save({
      plugin: "example.tokens",
      method: "mcpOAuth",
      values: {},
      secretsSet: [],
      status: "ok",
      createdAt: `2026-10-27T09:00:0${record.id.length % 10}.000Z`,
      ...record
    })
  return { accounts, server, vault: realVault, revoked, seed }
}

describe("plugin accounts", () => {
  it("names synced accounts by label, then identity, then id", async () => {
    const { accounts, server, seed } = await accountsFixture()
    await seed({ id: "a", label: "Work" })
    await seed({ id: "bb", identity: "dana@example.com" })
    await seed({ id: "ccc" })

    expect(await accounts.choices(server.id)).toEqual([
      { id: "a", label: "Work" },
      { id: "bb", label: "dana@example.com" },
      { id: "ccc", label: "ccc" }
    ])
  })

  it("gives plugins only the fields of an account that has no vault credential", async () => {
    const { accounts, server, seed } = await accountsFixture()
    await seed({ id: "a", values: { workspace: "acme" } })

    const context = await accounts.context(server.id)

    expect(context).toEqual({ id: "a", fields: { workspace: "acme" } })
  })

  it("passes a vault grant's access token even when it carries no field secrets", async () => {
    const { accounts, server, seed, vault } = await accountsFixture()
    const credential = await vault.create({
      harnessId: "plugin",
      subject: "dana",
      accessToken: "access-token",
      expiresAt: Number.MAX_SAFE_INTEGER,
      ownership: "managed"
    })
    await seed({ id: "a", label: "Imported", credential })

    expect(await accounts.context(server.id, "a")).toEqual({
      id: "a",
      label: "Imported",
      accessToken: "access-token",
      fields: {}
    })
  })

  it("has no context for a plugin without accounts or for an unknown account", async () => {
    const { accounts, server, seed } = await accountsFixture()
    const before = await accounts.context(server.id)
    await seed({ id: "a" })

    expect([before, await accounts.context(server.id, "missing")]).toEqual([undefined, undefined])
  })

  it("saves a token account without a label when nothing names it", async () => {
    const { accounts, server } = await accountsFixture()

    const saved = await accounts.saveFields(server.id, {
      values: { workspace: "acme", token: "t" }
    })

    expect(saved).not.toHaveProperty("label")
    expect(saved).toMatchObject({ values: { workspace: "acme" }, secretsSet: ["token"] })
  })

  it("still updates and removes accounts when the vault can't revoke old credentials", async () => {
    const { accounts, server, seed, revoked } = await accountsFixture({ revokeFails: true })
    const saved = await accounts.saveFields(server.id, {
      values: { workspace: "acme", token: "t" }
    })
    await seed({ id: "synced" })

    const updated = await accounts.saveFields(
      server.id,
      { label: "Acme", values: { workspace: "acme" } },
      saved.id
    )
    await accounts.remove(server.id, saved.id)
    await accounts.remove(server.id, "synced")

    expect(updated.label).toBe("Acme")
    expect(revoked).toHaveLength(2)
    expect(await accounts.list(server.id)).toEqual([])
  })
})
