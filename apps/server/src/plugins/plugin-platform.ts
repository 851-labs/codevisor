import type { McpServer } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import type { ManagedOAuthClients, McpManager } from "@codevisor/mcp"
import type { SyncEntryRecord } from "@codevisor/sync"

import type { CloudInbox } from "../infra/cloud-inbox.js"
import type { CloudServerControl } from "../server-context-types.js"
import { HttpFailure } from "../server-context.js"
import { field } from "../unknown-values.js"
import type { OAuthRedirects } from "./accounts/plugin-account-flows.js"
import { makePluginAccountStore } from "./accounts/plugin-account-store.js"
import {
  makePluginAccounts,
  type PluginAccounts,
  type PluginVault
} from "./accounts/plugin-accounts.js"
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
  readonly managedOAuth: ManagedOAuthClients
  readonly accountSource: {
    readonly list: (serverId: string) => Promise<ReadonlyArray<{ id: string; label: string }>>
    readonly meta: (
      serverId: string,
      accountId?: string
    ) => Promise<Record<string, unknown> | undefined>
  }
}

export interface PluginPlatformDeps {
  readonly db: CodevisorDatabaseService
  readonly serverId: string
  readonly vault: PluginVault
  readonly catalog: PluginCatalog
  readonly cloud: CloudServerControl | undefined
  readonly inbox: CloudInbox | undefined
  readonly localBaseUrl: string
}

export const makePluginPlatform = (deps: PluginPlatformDeps): PluginPlatform => {
  let mcp: McpManager | undefined
  const listeners = new Set<(entries: ReadonlyArray<SyncEntryRecord>) => void>()

  const server = async (serverId: string): Promise<McpServer> => {
    const found = (await requireMcp(mcp).list()).find((candidate) => candidate.id === serverId)
    if (found === undefined) throw new HttpFailure(404, `Plugin not found: ${serverId}`)
    return found
  }

  const accounts = makePluginAccounts({
    store: makePluginAccountStore(deps.db, deps.serverId),
    vault: deps.vault,
    server,
    spec: (found) =>
      found.catalogId === undefined ? undefined : deps.catalog.entry(found.catalogId)?.accounts,
    redirects: oauthRedirects(deps),
    onChanged: (entries) => {
      for (const listener of listeners) listener(entries)
    }
  })

  return {
    accounts,
    inbox: deps.inbox,
    cloudRequest: deps.cloud?.machineRequest,
    deviceId: () => deps.cloud?.deviceId(),
    attachMcp: (manager) => {
      mcp = manager
    },
    managedOAuth: managedOAuthClients(deps),
    onAccountsChanged: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    accountSource: {
      list: (serverId) => accounts.choices(serverId).catch(() => []),
      meta: async (serverId, accountId) => {
        const context = await accounts.context(serverId, accountId).catch(() => undefined)
        return context === undefined ? undefined : { ...context }
      }
    }
  }
}

const managedOAuthClients = (deps: PluginPlatformDeps): ManagedOAuthClients => ({
  clientId: async (client) => {
    const reply = await requireCloudRequest(deps)("GET", `/api/machine/oauth-clients/${client}`)
    const clientId = field(reply, "clientId")
    if (typeof clientId !== "string") throw new Error("The cloud didn't return an OAuth client")
    return clientId
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

const oauthRedirects = (deps: PluginPlatformDeps): OAuthRedirects => ({
  prepare: async () => loopbackRedirect(deps)
})

const loopbackRedirect = (deps: PluginPlatformDeps) => ({
  redirectUri: new URL("/v1/plugins/oauth/callback", deps.localBaseUrl).toString(),
  deviceId: "local"
})

const requireMcp = (mcp: McpManager | undefined): McpManager => {
  if (mcp === undefined) throw new HttpFailure(501, "Plugins unavailable")
  return mcp
}
