import type {
  SandboxAdapter,
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
  all: async () => [
    ...adapters
      .all()
      .filter((adapter) => needsNoAccount(adapter.definition))
      .filter((adapter) => adapters.runsHere(adapter.definition.id))
      .map((adapter) => ({ provider: adapter.definition.id })),
    ...(await settings.accounts())
      .filter((account) => adapters.get(account.provider) !== undefined)
      .map((account) => ({ provider: account.provider, accountId: account.id }))
  ]
})

export const requireAdapter = (
  adapters: SandboxAdapters,
  id: SandboxProviderId
): SandboxAdapter => {
  const adapter = adapters.get(id)
  if (adapter === undefined) throw new HttpFailure(404, `No sandbox provider ${id}`)
  return adapter
}

export const needsNoAccount = (definition: SandboxProviderDefinition): boolean =>
  definition.accountFields.length === 0

const accountFor = async (
  settings: Pick<SandboxSettings, "account">,
  definition: SandboxProviderDefinition,
  accountId: string | undefined
): Promise<StoredSandboxAccount | undefined> => {
  if (needsNoAccount(definition)) return undefined

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
  `Its ${definition.displayName} account was removed`
