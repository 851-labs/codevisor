import { randomUUID } from "node:crypto"

import {
  isoTimestamp,
  type McpServer,
  type PluginAccount,
  type PluginAccountOAuthStart,
  type PluginAccountSpec,
  type SavePluginAccountRequest
} from "@codevisor/api"
import type { SharedTokenBundle } from "@codevisor/harness-manager"
import type { SyncEntryRecord } from "@codevisor/sync"

import { HttpFailure } from "../../server-context.js"
import type { InstalledOAuthClients } from "./installed-oauth-clients.js"
import { splitFieldValues } from "./plugin-account-fields.js"
import { makePluginOAuthFlows, type OAuthRedirects } from "./plugin-account-flows.js"
import {
  publicAccount,
  type CredentialReference,
  type PluginAccountRecord,
  type PluginAccountStore
} from "./plugin-account-store.js"

export interface PluginVault {
  readonly create: (bundle: SharedTokenBundle) => Promise<CredentialReference>
  readonly token: (reference: CredentialReference, rejected?: string) => Promise<SharedTokenBundle>
  readonly revoke: (reference: CredentialReference) => Promise<void>
}

export interface AccountContext {
  readonly id: string
  readonly label?: string
  readonly identity?: string
  readonly accessToken?: string
  readonly fields: Readonly<Record<string, string | number | boolean>>
}

export interface PluginAccountsDeps {
  readonly store: PluginAccountStore
  readonly vault: PluginVault
  readonly server: (serverId: string) => Promise<McpServer>
  readonly spec: (server: McpServer) => PluginAccountSpec | undefined
  readonly redirects: OAuthRedirects
  readonly installedClients?: InstalledOAuthClients | undefined
  readonly beforeRemove?: (serverId: string, accountId: string) => Promise<void>
  readonly onChanged: (entries: ReadonlyArray<SyncEntryRecord>) => void
  readonly now?: () => number
  readonly fetch?: typeof fetch
}

export interface PluginAccounts {
  readonly list: (serverId: string) => Promise<ReadonlyArray<PluginAccount>>
  readonly saveFields: (
    serverId: string,
    request: SavePluginAccountRequest,
    accountId?: string
  ) => Promise<PluginAccount>
  readonly startOAuth: (
    serverId: string,
    request: SavePluginAccountRequest & { readonly accountId?: string }
  ) => Promise<PluginAccountOAuthStart>
  readonly completeOAuth: (state: string, code: string | undefined, error?: string) => Promise<void>
  readonly remove: (serverId: string, accountId: string) => Promise<void>
  readonly context: (serverId: string, accountId?: string) => Promise<AccountContext | undefined>
  readonly choices: (serverId: string) => Promise<ReadonlyArray<{ id: string; label: string }>>
}

export const pluginKeyOf = (server: McpServer): string => server.catalogId ?? server.name

export const makePluginAccounts = (deps: PluginAccountsDeps): PluginAccounts => {
  const now = deps.now ?? Date.now
  const flows = makePluginOAuthFlows({ ...deps, now, save: (record) => replace(record) })

  const save = async (record: PluginAccountRecord): Promise<PluginAccount> => {
    deps.onChanged(await deps.store.save(record))
    return publicAccount(record)
  }

  const replace = async (record: PluginAccountRecord): Promise<PluginAccount> => {
    const previous = await deps.store.get(record.id)
    const saved = await save(
      previous === undefined ? record : { ...record, createdAt: previous.createdAt }
    )
    if (previous?.credential !== undefined)
      await deps.vault.revoke(previous.credential).catch(() => undefined)
    return saved
  }

  const accountsOf = async (serverId: string) =>
    deps.store.list(pluginKeyOf(await deps.server(serverId)))

  const ownedAccount = async (serverId: string, accountId: string) => {
    const account = (await accountsOf(serverId)).find((record) => record.id === accountId)
    if (account === undefined) throw new HttpFailure(404, `Account not found: ${accountId}`)
    return account
  }

  const existingSecrets = async (record: PluginAccountRecord | undefined) => {
    if (record?.credential === undefined) return {}
    return secretsOf(await deps.vault.token(record.credential))
  }

  const contextOf = async (record: PluginAccountRecord): Promise<AccountContext> => {
    if (record.credential === undefined) return accountContext(record, undefined)
    return accountContext(record, await deps.vault.token(record.credential))
  }

  const previousAccount = async (serverId: string, accountId: string | undefined) => {
    if (accountId === undefined) return undefined
    return ownedAccount(serverId, accountId)
  }

  return {
    list: async (serverId) => (await accountsOf(serverId)).map(publicAccount),
    saveFields: async (serverId, request, accountId) => {
      const server = await deps.server(serverId)
      const spec = requireSpec(deps.spec(server), server)
      const previous = await previousAccount(serverId, accountId)
      const split = splitFieldValues(spec.fields, request.values, await existingSecrets(previous))
      const credential = await deps.vault.create(fieldsBundle(split.secrets))
      if (previous?.credential !== undefined)
        await deps.vault.revoke(previous.credential).catch(() => undefined)
      return save(fieldsRecord(server, request, split, credential, previous))
    },
    startOAuth: async (serverId, request) => {
      const server = await deps.server(serverId)
      const spec = requireSpec(deps.spec(server), server)
      const previous = await previousAccount(serverId, request.accountId)
      const split = splitFieldValues(spec.fields, request.values, await existingSecrets(previous))
      return flows.start(server, spec, {
        ...(request.label === undefined ? {} : { label: request.label }),
        previous,
        split
      })
    },
    completeOAuth: flows.complete,
    remove: async (serverId, accountId) => {
      const account = await ownedAccount(serverId, accountId)
      await deps.beforeRemove?.(serverId, account.id)
      if (account.credential !== undefined)
        await deps.vault.revoke(account.credential).catch(() => undefined)
      deps.onChanged(await deps.store.remove(account.id))
    },
    context: async (serverId, accountId) => {
      const accounts = await accountsOf(serverId)
      const chosen = accounts.find(
        (record) => accountId === undefined || record.id === accountId || record.label === accountId
      )
      return chosen === undefined ? undefined : contextOf(chosen)
    },
    choices: async (serverId) =>
      (await accountsOf(serverId)).map((record) => ({
        id: record.id,
        label: record.label ?? record.identity ?? record.id
      }))
  }
}

export const accountContext = (
  record: PluginAccountRecord,
  bundle: SharedTokenBundle | undefined
): AccountContext => ({
  id: record.id,
  ...(record.label === undefined ? {} : { label: record.label }),
  ...(record.identity === undefined ? {} : { identity: record.identity }),
  ...(bundle === undefined || bundle.authMethod === "apiKey"
    ? {}
    : { accessToken: bundle.accessToken }),
  fields: { ...record.values, ...(bundle === undefined ? {} : secretsOf(bundle)) }
})

export const secretsOf = (bundle: SharedTokenBundle): Readonly<Record<string, string>> => {
  const secrets = bundle.credential?.secrets
  if (typeof secrets !== "object" || secrets === null) return {}
  return Object.fromEntries(
    Object.entries(secrets).filter((pair): pair is [string, string] => typeof pair[1] === "string")
  )
}

const fieldsBundle = (secrets: Readonly<Record<string, string>>): SharedTokenBundle => ({
  harnessId: "plugin",
  authMethod: "apiKey",
  subject: randomUUID(),
  accessToken: "",
  expiresAt: Number.MAX_SAFE_INTEGER,
  ownership: "managed",
  credential: { secrets }
})

const fieldsRecord = (
  server: McpServer,
  request: SavePluginAccountRequest,
  split: ReturnType<typeof splitFieldValues>,
  credential: CredentialReference,
  previous: PluginAccountRecord | undefined
): PluginAccountRecord => ({
  id: previous?.id ?? randomUUID(),
  plugin: pluginKeyOf(server),
  ...labelOf(request.label, previous?.label, split.values),
  method: "fields",
  values: split.values,
  secretsSet: Object.keys(split.secrets).toSorted(),
  status: "ok",
  createdAt: previous?.createdAt ?? isoTimestamp(),
  credential
})

const labelOf = (
  requested: string | undefined,
  previous: string | undefined,
  values: Readonly<Record<string, string | number | boolean>>
): { readonly label?: string } => {
  const label = requested?.trim() || previous || defaultLabel(values)
  return label === undefined ? {} : { label }
}

const defaultLabel = (values: Readonly<Record<string, string | number | boolean>>) => {
  const url = values.url
  if (typeof url !== "string") return undefined
  return new URL(url).host
}

const requireSpec = (spec: PluginAccountSpec | undefined, server: McpServer): PluginAccountSpec => {
  if (spec !== undefined) return spec
  throw new HttpFailure(400, `${server.name} doesn't use Codevisor accounts`)
}
