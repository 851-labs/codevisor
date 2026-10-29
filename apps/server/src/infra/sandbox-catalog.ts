import type {
  SandboxAccount,
  SandboxProfile,
  SandboxProfileAvailability,
  SandboxProviderInfo,
  SaveSandboxAccountRequest,
  SaveSandboxProfileRequest
} from "@codevisor/api"
import {
  keepingSecrets,
  readAccountValues,
  readProfileOptions,
  SandboxChoiceNeeded,
  secretsSet,
  withoutSecrets,
  type SandboxAdapter,
  type SandboxFieldMaximums,
  type SandboxFieldValues,
  type SandboxProvider,
  type SandboxProviderDefinition
} from "@codevisor/sandboxes"

import { HttpFailure } from "../server-context.js"
import {
  accountById,
  missingAccountReason,
  requireAdapter,
  usesAccounts,
  type SandboxAdapters,
  type SandboxConnections
} from "./sandbox-connections.js"
import { connectionOf } from "./sandbox-profile-record.js"
import type {
  SandboxSettings,
  SandboxSettingsChange,
  StoredSandboxAccount
} from "./sandbox-settings.js"

export interface SandboxCatalogDeps {
  readonly settings: SandboxSettings
  readonly adapters: SandboxAdapters
  readonly connections: SandboxConnections
  readonly serverId: string
  readonly sandboxesUsing: (accountId: string) => Promise<number>
  readonly retireSandboxes: (accountId: string) => Promise<void>
  readonly newId: () => string
  readonly now: () => number
}

export interface SavedAccount {
  readonly account: SandboxAccount
  readonly change: SandboxSettingsChange
}

export interface SavedProfile {
  readonly profile: SandboxProfile
  readonly change: SandboxSettingsChange
}

export const providerInfos = (adapters: SandboxAdapters): ReadonlyArray<SandboxProviderInfo> =>
  adapters.all().map((adapter) => adapter.definition)

export const hostCapabilities = (adapters: SandboxAdapters): ReadonlyArray<string> =>
  adapters
    .all()
    .filter((adapter) => adapters.runsHere(adapter.definition.id))
    .flatMap((adapter) => machineCapabilities(adapter.definition))

export const hostMaximums = (
  adapters: SandboxAdapters
): Readonly<Record<string, SandboxFieldMaximums>> =>
  Object.fromEntries(
    adapters
      .all()
      .filter((adapter) => adapters.runsHere(adapter.definition.id))
      .flatMap((adapter) => maximumsOf(adapter))
  )

export const listAccounts = async (
  deps: SandboxCatalogDeps
): Promise<ReadonlyArray<SandboxAccount>> =>
  (await deps.settings.accounts()).flatMap((account) => {
    const adapter = deps.adapters.get(account.provider)
    return adapter === undefined ? [] : [accountSummary(adapter.definition, account)]
  })

export const createAccount = async (
  deps: SandboxCatalogDeps,
  request: SaveSandboxAccountRequest
): Promise<SavedAccount> => {
  const adapter = accountAdapter(deps, request.provider)
  const values = asFieldInput(() => readAccountValues(adapter.definition, request.values))
  const account: StoredSandboxAccount = {
    id: deps.newId(),
    provider: request.provider,
    ...labelOf(request),
    ...(await verified(adapter, values)),
    createdAt: new Date(deps.now()).toISOString()
  }
  return saveAccount(deps, adapter.definition, account)
}

export const updateAccount = async (
  deps: SandboxCatalogDeps,
  id: string,
  request: SaveSandboxAccountRequest
): Promise<SavedAccount> => {
  const previous = await existingAccount(deps, id)
  if (request.provider !== previous.provider) {
    throw new HttpFailure(400, "A provider can't move to another vendor")
  }
  const adapter = accountAdapter(deps, previous.provider)
  const raw = keepingSecrets(adapter.definition.accountFields, previous.values, request.values)
  const values = asFieldInput(() => readAccountValues(adapter.definition, raw))
  const account = {
    id: previous.id,
    provider: previous.provider,
    ...labelOf(request),
    ...(await verified(adapter, values)),
    createdAt: previous.createdAt
  }
  return saveAccount(deps, adapter.definition, account)
}

export const deleteAccount = async (
  deps: SandboxCatalogDeps,
  id: string
): Promise<SandboxSettingsChange> => {
  await existingAccount(deps, id)
  const users = (await deps.settings.profiles()).filter((profile) => profile.accountId === id)
  if (users.length > 0) throw new HttpFailure(409, accountInUseByProfiles(users))

  const running = await deps.sandboxesUsing(id)
  if (running > 0) throw new HttpFailure(409, accountInUseBySandboxes(running))

  return deps.settings.removeAccount(id)
}

export const deleteAccountAndUsers = async (
  deps: SandboxCatalogDeps,
  id: string
): Promise<ReadonlyArray<SandboxSettingsChange>> => {
  await deps.retireSandboxes(id)
  const profileChanges = await removeProfilesUsing(deps, id)
  if ((await deps.settings.account(id)) === undefined) return profileChanges

  return [...profileChanges, await deps.settings.removeAccount(id)]
}

export const createProfile = async (
  deps: SandboxCatalogDeps,
  request: SaveSandboxProfileRequest
): Promise<SavedProfile> => {
  const profile = {
    id: deps.newId(),
    ...(await validProfile(deps, request)),
    createdAt: new Date(deps.now()).toISOString()
  }
  return { profile, change: await deps.settings.putProfile(profile) }
}

export const updateProfile = async (
  deps: SandboxCatalogDeps,
  id: string,
  request: SaveSandboxProfileRequest
): Promise<SavedProfile> => {
  const previous = await existingProfile(deps, id)
  const profile = { id, ...(await validProfile(deps, request)), createdAt: previous.createdAt }
  return { profile, change: await deps.settings.putProfile(profile) }
}

export const deleteProfile = async (
  deps: SandboxCatalogDeps,
  id: string
): Promise<SandboxSettingsChange> => {
  await existingProfile(deps, id)
  return deps.settings.removeProfile(id)
}

export const profileAvailability = async (
  deps: SandboxCatalogDeps
): Promise<ReadonlyArray<SandboxProfileAvailability>> =>
  Promise.all(
    (await deps.settings.profiles()).map(async (profile) => ({
      profileId: profile.id,
      ...(await unavailability(deps, profile))
    }))
  )

export const existingProfile = async (
  deps: Pick<SandboxCatalogDeps, "settings">,
  id: string
): Promise<SandboxProfile> => {
  const profile = await deps.settings.profile(id)
  if (profile === undefined) throw new HttpFailure(404, `No sandbox profile ${id}`)
  return profile
}

export const placementOf = async (
  deps: Pick<SandboxCatalogDeps, "connections">,
  profile: SandboxProfile
): Promise<SandboxFieldValues> => ({
  ...profile.values,
  ...(await deps.connections.providerValues(connectionOf(profile)))
})

export const runsElsewhere = (
  definition: SandboxProviderDefinition,
  values: SandboxFieldValues,
  serverId: string
): boolean =>
  [...definition.accountFields, ...definition.profileFields].some(
    (field) =>
      field.type === "machine" && values[field.key] !== undefined && values[field.key] !== serverId
  )

const removeProfilesUsing = async (
  deps: SandboxCatalogDeps,
  accountId: string
): Promise<ReadonlyArray<SandboxSettingsChange>> => {
  const users = (await deps.settings.profiles()).filter(
    (profile) => profile.accountId === accountId
  )
  const changes: SandboxSettingsChange[] = []
  for (const profile of users) changes.push(await deps.settings.removeProfile(profile.id))
  return changes
}

interface Unavailability {
  readonly disabledReason?: string
  readonly full?: true
}

const unavailability = async (
  deps: SandboxCatalogDeps,
  profile: SandboxProfile
): Promise<Unavailability> => {
  const reason = await disabledReasonFor(deps, profile)
  if (reason !== undefined) return { disabledReason: reason }

  const full = await checked(deps, profile, (provider) => provider.capacity?.(profile.values))
  return full === undefined ? {} : { disabledReason: full, full: true }
}

const disabledReasonFor = async (
  deps: SandboxCatalogDeps,
  profile: SandboxProfile
): Promise<string | undefined> => {
  const adapter = deps.adapters.get(profile.provider)
  if (adapter === undefined) return `Update Codevisor to use ${profile.provider} sandboxes`

  const { definition } = adapter
  if (runsElsewhere(definition, await placementOf(deps, profile), deps.serverId))
    return "Runs on another Mac"
  if (!deps.adapters.runsHere(definition.id))
    return `${definition.displayName} can't run on this machine`
  if (await accountMissing(deps, definition, profile)) return missingAccountReason(definition)

  return checked(deps, profile, (provider) => provider.availability?.(profile.values))
}

const checked = async (
  deps: SandboxCatalogDeps,
  profile: SandboxProfile,
  check: (provider: SandboxProvider) => Promise<string | undefined> | undefined
): Promise<string | undefined> => {
  try {
    return await check(await deps.connections.connect(connectionOf(profile)))
  } catch {
    return undefined
  }
}

const accountMissing = async (
  deps: SandboxCatalogDeps,
  definition: SandboxProviderDefinition,
  profile: SandboxProfile
): Promise<boolean> => {
  if (!usesAccounts(definition)) return false
  return (await accountById(deps.settings, profile.accountId)) === undefined
}

const validProfile = async (
  deps: SandboxCatalogDeps,
  request: SaveSandboxProfileRequest
): Promise<Omit<SandboxProfile, "id" | "createdAt">> => {
  const name = request.name.trim()
  if (name === "") throw new HttpFailure(400, "Name is required")

  const adapter = requireAdapter(deps.adapters, request.provider)
  const { definition } = adapter
  const accountId = await profileAccount(deps, definition, request.accountId)
  const maximums = await maximumsForProfile(deps, adapter, accountId)
  const values = asFieldInput(() => readProfileOptions(definition, request.values, maximums))
  return {
    name,
    provider: request.provider,
    ...(accountId === undefined ? {} : { accountId }),
    values
  }
}

const maximumsForProfile = async (
  deps: SandboxCatalogDeps,
  adapter: SandboxAdapter,
  accountId: string | undefined
): Promise<SandboxFieldMaximums> => {
  const account = await accountById(deps.settings, accountId)
  if (runsElsewhere(adapter.definition, account?.values ?? {}, deps.serverId)) return {}
  return adapter.hostMaximums?.() ?? {}
}

const profileAccount = async (
  deps: SandboxCatalogDeps,
  definition: SandboxProviderDefinition,
  accountId: string | undefined
): Promise<string | undefined> => {
  if (!usesAccounts(definition)) return undefined

  const account = await accountById(deps.settings, accountId)
  if (account?.provider !== definition.id) {
    throw new HttpFailure(400, `Choose a ${definition.displayName} provider`)
  }
  return account.id
}

const accountAdapter = (deps: SandboxCatalogDeps, id: SandboxAdapter["definition"]["id"]) => {
  const adapter = requireAdapter(deps.adapters, id)
  if (!usesAccounts(adapter.definition)) {
    throw new HttpFailure(400, `${adapter.definition.displayName} doesn't use providers`)
  }
  return adapter
}

const existingAccount = async (
  deps: SandboxCatalogDeps,
  id: string
): Promise<StoredSandboxAccount> => {
  const account = await deps.settings.account(id)
  if (account === undefined) throw new HttpFailure(404, `No sandbox provider ${id}`)
  return account
}

const saveAccount = async (
  deps: SandboxCatalogDeps,
  definition: SandboxProviderDefinition,
  account: StoredSandboxAccount
): Promise<SavedAccount> => ({
  account: accountSummary(definition, account),
  change: await deps.settings.putAccount(account)
})

const verified = async (
  adapter: SandboxAdapter,
  values: SandboxFieldValues
): Promise<{ readonly identity?: string; readonly values: SandboxFieldValues }> => {
  try {
    const { identity, resolved } = (await adapter.verify?.(values)) ?? {}
    return { ...(identity === undefined ? {} : { identity }), values: { ...values, ...resolved } }
  } catch (cause) {
    if (cause instanceof SandboxChoiceNeeded) {
      throw new HttpFailure(409, cause.message, "sandboxChoiceNeeded", { field: cause.field })
    }
    throw new HttpFailure(
      400,
      `${adapter.definition.displayName} didn't accept these credentials: ${messageOf(cause)}`
    )
  }
}

const accountSummary = (
  definition: SandboxProviderDefinition,
  account: StoredSandboxAccount
): SandboxAccount => ({
  ...account,
  values: withoutSecrets(definition.accountFields, account.values),
  secretsSet: secretsSet(definition.accountFields, account.values)
})

const labelOf = (request: SaveSandboxAccountRequest): { readonly label?: string } => {
  const label = request.label?.trim() ?? ""
  return label === "" ? {} : { label }
}

const maximumsOf = (
  adapter: SandboxAdapter
): ReadonlyArray<readonly [string, SandboxFieldMaximums]> => {
  const maximums = adapter.hostMaximums?.()
  return maximums === undefined ? [] : [[adapter.definition.id, maximums]]
}

const machineCapabilities = (definition: SandboxProviderDefinition): ReadonlyArray<string> =>
  [...definition.accountFields, ...definition.profileFields].flatMap((field) =>
    field.type === "machine" && field.capability !== undefined ? [field.capability] : []
  )

const accountInUseByProfiles = (profiles: ReadonlyArray<SandboxProfile>): string => {
  const names = profiles.map((profile) => profile.name).join(", ")
  if (profiles.length === 1)
    return `${names} uses this provider; change or delete that profile first`
  return `${names} use this provider; change or delete those profiles first`
}

const accountInUseBySandboxes = (count: number): string => {
  if (count === 1) return "A sandbox is still running on this provider"
  return `${count} sandboxes are still running on this provider`
}

const asFieldInput = <T>(read: () => T): T => {
  try {
    return read()
  } catch (cause) {
    throw new HttpFailure(400, messageOf(cause))
  }
}

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
