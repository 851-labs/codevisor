import { randomBytes } from "node:crypto"
import { dirname } from "node:path"

import type { PluginAccountSpec } from "@codevisor/api"
import type { McpOAuthRelay } from "@codevisor/mcp"
import type { SyncEntryRecord } from "@codevisor/sync"
import { expect } from "vitest"

import { manualOAuthClock, sharedCoordinator } from "../../infra/mcp-oauth-test-support.js"
import { mcpCredentialVault } from "../../infra/shared-account-storage.js"
import { HttpFailure } from "../../server-context.js"
import { makeServices } from "../../test-support.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import type { InstalledOAuthClients } from "./installed-oauth-clients.js"
import { makePluginAccountStore } from "./plugin-account-store.js"
import { makePluginAccounts } from "./plugin-accounts.js"
import { sealedPendingOAuthStorage } from "./plugin-oauth-storage.js"
import {
  fakeOAuthProvider,
  type FakeOAuthProvider,
  type ProviderOptions
} from "./plugin-oauth-test-support.js"

export const callbackUrl = "http://127.0.0.1:43210/v1/plugins/oauth/callback"

export const clientFields: PluginAccountSpec["fields"] = [
  { key: "clientId", label: "OAuth client ID", type: "string", required: true },
  { key: "clientSecret", label: "OAuth client secret", type: "secret", required: true }
]

export interface FixtureOptions {
  readonly catalogId?: string
  readonly revokeFails?: boolean
  readonly installedClients?: InstalledOAuthClients
  readonly relay?: McpOAuthRelay
}

export const oauthFixture = async (
  specFor: (provider: FakeOAuthProvider) => PluginAccountSpec | undefined,
  options: ProviderOptions = {},
  fixtureOptions: FixtureOptions = { catalogId: "example.mail" }
) => {
  const { services } = await makeServices("server-a")
  const clock = manualOAuthClock(Date.UTC(2026, 9, 27, 9))
  const vault = mcpCredentialVault(
    dirname(services.attachments.root),
    sharedCoordinator(clock).machine("server-a"),
    clock.now
  )
  const provider = await fakeOAuthProvider(options)
  const server = await savePluginRow(
    services.db,
    "Mail",
    fixtureOptions.catalogId === undefined ? {} : { catalogId: fixtureOptions.catalogId }
  )
  const changes: Array<ReadonlyArray<SyncEntryRecord>> = []
  const pendingStorage = sealedPendingOAuthStorage(services.db, randomBytes(32))
  const build = () =>
    makePluginAccounts({
      store: makePluginAccountStore(services.db, "server-a", clock.now),
      vault:
        fixtureOptions.revokeFails === true
          ? { ...vault, revoke: () => Promise.reject(new Error("vault offline")) }
          : vault,
      server: async (serverId) => {
        if (serverId === server.id) return server
        throw new HttpFailure(404, `Plugin not found: ${serverId}`)
      },
      spec: () => specFor(provider),
      redirects: { loopbackUri: callbackUrl, relay: fixtureOptions.relay },
      pendingStorage,
      ...(fixtureOptions.installedClients === undefined
        ? {}
        : { installedClients: fixtureOptions.installedClients }),
      onChanged: (entries) => changes.push(entries),
      now: clock.now
    })
  const accounts = build()
  const signIn = async (
    request: {
      readonly label?: string
      readonly accountId?: string
      readonly values?: Record<string, unknown>
      readonly callbackScheme?: string
    } = {}
  ) => {
    const started = await accounts.startOAuth(server.id, {
      values: request.values ?? { clientId: "client-1", clientSecret: "client-secret" },
      ...(request.label === undefined ? {} : { label: request.label }),
      ...(request.callbackScheme === undefined ? {} : { callbackScheme: request.callbackScheme }),
      ...(request.accountId === undefined ? {} : { accountId: request.accountId })
    })
    return { started, grant: provider.authorize(started.authorizationUrl) }
  }
  const storedCredential = async (accountId: string) => {
    const record = await makePluginAccountStore(services.db, "server-a").get(accountId)
    return record!.credential!
  }
  return {
    accounts,
    provider,
    server,
    clock,
    vault,
    changes,
    signIn,
    storedCredential,
    restarted: build,
    db: services.db
  }
}

export const exampleSpec = (provider: FakeOAuthProvider): PluginAccountSpec => ({
  label: "Example account",
  oauth: provider.spec({ authorizeParams: { access_type: "offline" } }),
  fields: clientFields
})

export const cloudRedirect = "https://cloud.example/oauth/plugins/callback"

export const appRedirectSpec = (provider: FakeOAuthProvider): PluginAccountSpec => ({
  ...exampleSpec(provider),
  oauth: provider.spec({ redirectUrl: cloudRedirect })
})

export const failure = (status: number, message: string) =>
  expect.objectContaining({ status, message })
