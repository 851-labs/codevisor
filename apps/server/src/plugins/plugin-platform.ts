import type { McpServer } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { ManagedOAuthClients, McpManager, McpManagerConfig } from "@codevisor/mcp"
import type { SyncEntryRecord } from "@codevisor/sync"

import type { CloudInbox, InboxOAuthCallback, InboxOAuthOutcome } from "../infra/cloud-inbox.js"
import type { CloudServerControl } from "../server-context-types.js"
import { HttpFailure } from "../server-context.js"
import { field } from "../unknown-values.js"
import type { InstalledOAuthClients } from "./accounts/installed-oauth-clients.js"
import { checkPluginAccount } from "./accounts/plugin-account-check.js"
import { makePluginAccountStore } from "./accounts/plugin-account-store.js"
import {
  makePluginAccounts,
  type PluginAccounts,
  type PluginVault
} from "./accounts/plugin-accounts.js"
import { sealedPendingOAuthStorage } from "./accounts/plugin-oauth-storage.js"
import { makeOAuthRelay, type OAuthRelay } from "./oauth-relay.js"
import type { PluginCatalog } from "./plugin-catalog.js"

export interface PluginPlatform {
  readonly accounts: PluginAccounts
  readonly inbox: CloudInbox | undefined
  readonly cloudRequest: CloudServerControl["machineRequest"]
  readonly deviceId: () => string | undefined
  readonly attachMcp: (mcp: McpManager) => void
  readonly onAccountsChanged: (
    listener: (entries: ReadonlyArray<SyncEntryRecord>) => void
  ) => () => void
  readonly onAccountRemoving: (listener: AccountRemovingListener) => () => void
  readonly mcpOAuth: Pick<McpManagerConfig, "managedOAuth" | "oauthRelay">
  readonly accountSource: {
    readonly list: (serverId: string) => Promise<ReadonlyArray<{ id: string; label: string }>>
    readonly meta: (
      serverId: string,
      accountId?: string
    ) => Promise<Record<string, unknown> | undefined>
  }
}

export type AccountRemovingListener = (serverId: string, accountId: string) => Promise<void>

export interface PluginPlatformDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly vault: PluginVault
  readonly catalog: PluginCatalog
  readonly cloud: CloudServerControl | undefined
  readonly inbox: CloudInbox | undefined
  readonly localBaseUrl: string
  readonly installedClients?: InstalledOAuthClients
  readonly secretKey?: Buffer
  readonly appScheme?: string
}

export const makePluginPlatform = (deps: PluginPlatformDeps): PluginPlatform => {
  let mcp: McpManager | undefined
  const listeners = new Set<(entries: ReadonlyArray<SyncEntryRecord>) => void>()
  const removing = new Set<AccountRemovingListener>()

  const server = async (serverId: string): Promise<McpServer> => {
    const found = (await requireMcp(mcp).list()).find((candidate) => candidate.id === serverId)
    if (found === undefined) throw new HttpFailure(404, `Plugin not found: ${serverId}`)
    return found
  }

  const relay = oauthRelayFor(deps)
  const accounts = makePluginAccounts({
    store: makePluginAccountStore(deps.db, deps.serverId),
    vault: deps.vault,
    server,
    spec: (found) =>
      found.catalogId === undefined ? undefined : deps.catalog.entry(found.catalogId)?.accounts,
    redirects: { loopbackUri: loopbackUri(deps), relay },
    pendingStorage:
      deps.secretKey === undefined ? undefined : sealedPendingOAuthStorage(deps.db, deps.secretKey),
    installedClients: deps.installedClients,
    check: (found, account) =>
      checkPluginAccount((id) => requireMcp(mcp).pluginConnection(id), found.id, account),
    beforeRemove: async (serverId, accountId) => {
      await Promise.allSettled([...removing].map((listener) => listener(serverId, accountId)))
    },
    onChanged: (entries) => {
      for (const listener of listeners) listener(entries)
    }
  })

  deps.inbox?.onOAuth((callback) => completeRelayedOAuth(accounts, mcp, callback))

  return {
    accounts,
    inbox: deps.inbox,
    cloudRequest: deps.cloud?.machineRequest,
    deviceId: () => deps.cloud?.deviceId(),
    attachMcp: (manager) => {
      mcp = manager
    },
    mcpOAuth: { managedOAuth: managedOAuthClients(deps), oauthRelay: relay },
    onAccountsChanged: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    onAccountRemoving: (listener) => {
      removing.add(listener)
      return () => {
        removing.delete(listener)
      }
    },
    accountSource: {
      list: (serverId) => accounts.choices(serverId).catch(() => []),
      meta: async (serverId, accountId) => {
        const context = await accounts.context(serverId, accountId).catch(() => undefined)
        if (context === undefined) return undefined

        const { routeKey: _routeKey, routeKeys: _routeKeys, ...meta } = context
        return meta
      }
    }
  }
}

const completeRelayedOAuth = async (
  accounts: PluginAccounts,
  mcp: McpManager | undefined,
  callback: InboxOAuthCallback
): Promise<InboxOAuthOutcome> => {
  try {
    await finishRelayedOAuth(accounts, mcp, callback)
    return { ok: true }
  } catch (cause) {
    console.log(`A relayed sign-in didn't finish: ${errorText(cause)}`)
    return { ok: false, error: errorText(cause).slice(0, maxReportedError) }
  }
}

const maxReportedError = 300

const finishRelayedOAuth = async (
  accounts: PluginAccounts,
  mcp: McpManager | undefined,
  callback: InboxOAuthCallback
): Promise<void> => {
  if (await accounts.ownsOAuthState(callback.state)) {
    return accounts.completeOAuth(callback.state, callback.code, callback.error)
  }
  if (mcp === undefined) throw new Error("Plugins aren't available on this machine")
  if (callback.code === undefined) throw new Error(callback.error ?? "The sign-in returned no code")

  await mcp.finishOAuth(callback.state, callback.code, callback.issuer)
}

const errorText = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const oauthRelayFor = (deps: PluginPlatformDeps): OAuthRelay =>
  makeOAuthRelay({
    cloud: deps.cloud,
    appScheme: deps.appScheme ?? "codevisor",
    log: (message) => console.log(message)
  })

const managedOAuthClients = (deps: PluginPlatformDeps): ManagedOAuthClients => ({
  client: async (client) => {
    const reply = await requireCloudRequest(deps)("GET", `/api/machine/oauth-clients/${client}`)
    const clientId = field(reply, "clientId")
    if (typeof clientId !== "string") throw new Error("The cloud didn't return an OAuth client")
    return { clientId, cloudCallback: field(reply, "cloudCallback") === true }
  },
  exchange: (client, tokenUrl, form) =>
    requireCloudRequest(deps)("POST", `/api/machine/oauth-clients/${client}/token`, {
      tokenUrl,
      form
    })
})

const requireCloudRequest = (deps: PluginPlatformDeps) => {
  const request = deps.cloud?.machineRequest
  if (request === undefined)
    throw new HttpFailure(409, "Sign in to Codevisor to connect this plugin")
  return request
}

const loopbackUri = (deps: PluginPlatformDeps): string =>
  new URL("/v1/plugins/oauth/callback", deps.localBaseUrl).toString()

const requireMcp = (mcp: McpManager | undefined): McpManager => {
  if (mcp === undefined) throw new HttpFailure(501, "Plugins unavailable")
  return mcp
}
