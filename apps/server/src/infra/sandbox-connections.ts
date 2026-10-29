import type {
  SandboxAdapter,
  SandboxFieldValues,
  SandboxProvider,
  SandboxProviderDefinition,
  SandboxProviderId
} from "@codevisor/sandboxes"

import { HttpFailure } from "../server-context.js"
import type { SandboxSettings, StoredSandboxAccount } from "./sandbox-settings.js"

export interface SandboxConnection {
  readonly provider: SandboxProviderId
  readonly accountId?: string
}

export interface SandboxAdapters {
  readonly get: (id: SandboxProviderId) => SandboxAdapter | undefined
  readonly all: () => ReadonlyArray<SandboxAdapter>
  readonly runsHere: (id: SandboxProviderId) => boolean
}

export interface SandboxConnections {
  readonly connect: (connection: SandboxConnection) => Promise<SandboxProvider>
  readonly providerValues: (connection: SandboxConnection) => Promise<SandboxFieldValues>
  readonly all: () => Promise<ReadonlyArray<SandboxConnection>>
}

export const makeSandboxAdapters = (
  adapters: ReadonlyArray<SandboxAdapter>,
  runsHere: (id: SandboxProviderId) => boolean
): SandboxAdapters => ({
  get: (id) => adapters.find((adapter) => adapter.definition.id === id),
  all: () => adapters,
  runsHere
})

export const makeSandboxConnections = (
  adapters: SandboxAdapters,
  settings: Pick<SandboxSettings, "accounts" | "account">
): SandboxConnections => ({
  connect: async (connection) => {
    const adapter = requireAdapter(adapters, connection.provider)
    const account = await accountFor(settings, adapter.definition, connection.accountId)
    return adapter.connect(account?.values ?? {})
  },
  providerValues: async (connection) =>
    (await accountById(settings, connection.accountId))?.values ?? {},
  all: async () => [
    ...adapters
      .all()
      .filter((adapter) => connectsWithoutAccount(adapter.definition))
      .filter((adapter) => adapters.runsHere(adapter.definition.id))
      .map((adapter) => ({ provider: adapter.definition.id })),
    ...(await settings.accounts())
      .filter((account) => needsStoredAccount(adapters.get(account.provider)))
      .map((account) => ({ provider: account.provider, accountId: account.id }))
  ]
})

export const requireAdapter = (
  adapters: SandboxAdapters,
  id: SandboxProviderId
): SandboxAdapter => {
  const adapter = adapters.get(id)
  if (adapter === undefined) throw new HttpFailure(404, `No sandbox vendor ${id}`)
  return adapter
}

export const hostsLocally = (definition: SandboxProviderDefinition | undefined): boolean =>
  definition !== undefined &&
  [...definition.accountFields, ...definition.profileFields].some(
    (field) => field.type === "machine"
  )

export const usesAccounts = (definition: SandboxProviderDefinition): boolean =>
  definition.accountFields.length > 0

export const connectsWithoutAccount = (definition: SandboxProviderDefinition): boolean =>
  definition.accountFields.every((field) => field.type === "machine")

const needsStoredAccount = (adapter: SandboxAdapter | undefined): boolean =>
  adapter !== undefined && !connectsWithoutAccount(adapter.definition)

const accountFor = async (
  settings: Pick<SandboxSettings, "account">,
  definition: SandboxProviderDefinition,
  accountId: string | undefined
): Promise<StoredSandboxAccount | undefined> => {
  if (connectsWithoutAccount(definition)) return undefined

  const account = await accountById(settings, accountId)
  if (account === undefined) throw new HttpFailure(409, missingAccountReason(definition))
  return account
}

export const accountById = async (
  settings: Pick<SandboxSettings, "account">,
  accountId: string | undefined
): Promise<StoredSandboxAccount | undefined> => {
  if (accountId === undefined) return undefined
  return settings.account(accountId)
}

export const missingAccountReason = (definition: SandboxProviderDefinition): string =>
  `Its ${definition.displayName} provider was removed`
