import { CLAUDE_AGENT_PROVIDER } from "@codevisor/adapter-opencode"
import type { OpenCodeAuthMethod, OpenCodeAuthProvider, PiAuthProvider } from "@codevisor/api"
import type { HarnessAccountRecord } from "@codevisor/db"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { providerOAuthSupported } from "@codevisor/harness-manager"
import type { SyncEntryRecord } from "@codevisor/sync"

import { HttpFailure, run, writeJson } from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"
import { disableCaching, readSharedAccountAction } from "./shared-account-actions.js"
import type { SharedAccountAction, SharedAccountsRoute } from "./shared-account-actions.js"

export interface ProviderAccounts {
  readonly harnessId: "pi" | "opencode"
  readonly singleProfile: boolean
  readonly listProviders: (accounts: SharedAccountsRoute, accountId: string) => Promise<boolean>
  readonly beginLogin: (
    accounts: SharedAccountsRoute,
    input: ProviderLogin,
    accountId: string
  ) => Promise<boolean>
}

type ProviderLogin = SharedAccountAction & { readonly providerId: string }

type CredentialType = "oauth" | undefined

type ProfileRestoringAuth = HarnessAuthManager &
  Required<Pick<HarnessAuthManager, "sharedOpenCodeProfiles">>

const defaultProfile = "default"

export const providerAccountsFor = (harnessId: string): ProviderAccounts | undefined =>
  providerAccounts.get(harnessId)

export const routeProviderAccounts = async (
  accounts: SharedAccountsRoute,
  provider: ProviderAccounts
): Promise<boolean> => {
  const input = await readSharedAccountAction(accounts.request)
  disableCaching(accounts.response)

  if (provider.singleProfile) return routeProviderAction(accounts, provider, input, defaultProfile)

  const profile = input.accountId ?? defaultProfile
  let account = await findOpenCodeProfile(accounts.services, profile)
  if (canRestoreProfiles(account, accounts.auth)) {
    account = await restoreOpenCodeProfile(accounts.services, accounts.auth, profile)
  }
  if (!account) throw new HttpFailure(404, "OpenCode profile not found")

  return routeProviderAction(accounts, provider, input, account.id)
}

const routeProviderAction = (
  accounts: SharedAccountsRoute,
  provider: ProviderAccounts,
  input: SharedAccountAction,
  accountId: string
): Promise<boolean> => {
  if (input.action === "providers") return provider.listProviders(accounts, accountId)
  if (input.action === "login") {
    return provider.beginLogin(accounts, requireSharedOAuth(provider, input), accountId)
  }
  if (removesProvider(input)) return removeProvider(accounts, provider, input, accountId)
  throw new HttpFailure(400, "Unknown provider account action")
}

const findOpenCodeProfile = async (
  services: CodevisorServerServices,
  profile: string
): Promise<HarnessAccountRecord | undefined> =>
  matchingProfile(await openCodeProfiles(services), profile)

const restoreOpenCodeProfile = async (
  services: CodevisorServerServices,
  auth: ProfileRestoringAuth,
  profile: string
): Promise<HarnessAccountRecord | undefined> => {
  const saved = savedOpenCodeProfiles(await run(services.db.getSyncEntries("harness-credentials")))
  if (typeof saved?.value !== "string") return undefined

  await auth.sharedOpenCodeProfiles(saved.value)
  return matchingProfile(await openCodeProfiles(services), profile)
}

const openCodeProfiles = (
  services: CodevisorServerServices
): Promise<ReadonlyArray<HarnessAccountRecord>> => run(services.db.listHarnessAccounts("opencode"))

const matchingProfile = (
  rows: ReadonlyArray<HarnessAccountRecord>,
  profile: string
): HarnessAccountRecord | undefined => rows.find((row) => isProfile(row, profile))

const isProfile = (row: HarnessAccountRecord, profile: string): boolean =>
  profile === defaultProfile ? row.profileKind === "default" : row.id === profile

const canRestoreProfiles = (
  account: HarnessAccountRecord | undefined,
  auth: HarnessAuthManager
): auth is ProfileRestoringAuth => !account && auth.sharedOpenCodeProfiles !== undefined

const savedOpenCodeProfiles = (
  entries: ReadonlyArray<SyncEntryRecord>
): SyncEntryRecord | undefined => entries.find(isSavedOpenCodeProfiles)

const isSavedOpenCodeProfiles = (entry: SyncEntryRecord): boolean =>
  entry.key === "profiles:opencode" && entry.deleted !== true

const requireSharedOAuth = (
  provider: ProviderAccounts,
  input: SharedAccountAction
): ProviderLogin => {
  if (!supportsSharedOAuth(provider, input)) {
    throw new HttpFailure(400, "This provider does not support shared OAuth")
  }
  return input
}

const supportsSharedOAuth = (
  provider: ProviderAccounts,
  input: SharedAccountAction
): input is ProviderLogin => {
  if (!input.providerId) return false
  return sharesSignIn(provider.harnessId, input.providerId)
}

const sharesSignIn = (harnessId: ProviderAccounts["harnessId"], providerId: string): boolean =>
  providerOAuthSupported(harnessId, providerId) ||
  (harnessId === "opencode" && providerId === CLAUDE_AGENT_PROVIDER)

const removesProvider = (input: SharedAccountAction): boolean =>
  input.action === "logout" || input.action === "remove"

const removeProvider = async (
  { shared, response }: SharedAccountsRoute,
  provider: ProviderAccounts,
  input: SharedAccountAction,
  accountId: string
): Promise<boolean> => {
  if (!input.providerId) throw new HttpFailure(400, "Choose a provider")

  await shared.providers.remove(provider.harnessId, accountId, input.providerId, true)
  writeJson(response, 200, {})
  return true
}

const listPiProviders = async (
  { shared, auth, response }: SharedAccountsRoute,
  accountId: string
): Promise<boolean> => {
  const configured = await shared.providers.configured("pi", accountId, true)
  if (!auth.piProviders) throw new HttpFailure(501, "Pi authentication unavailable")

  const providers = (await auth.piProviders()).map((piProvider) =>
    withPiCredentialType(piProvider, configured)
  )
  writeJson(response, 200, { piProviders: providers })
  return true
}

const listOpenCodeProviders = async (
  { shared, auth, response }: SharedAccountsRoute,
  accountId: string
): Promise<boolean> => {
  const configured = await shared.providers.configured("opencode", accountId, true)
  if (!auth.openCodeProviders) throw new HttpFailure(501, "OpenCode authentication unavailable")

  const providers = (await auth.openCodeProviders(accountId, true)).map((openCodeProvider) =>
    withSharedOAuthMethods(openCodeProvider, configured)
  )
  writeJson(response, 200, { openCodeProviders: providers })
  return true
}

const withPiCredentialType = (
  provider: PiAuthProvider,
  configured: ReadonlyArray<string>
): Omit<PiAuthProvider, "credentialType"> & { readonly credentialType: CredentialType } => ({
  ...provider,
  credentialType: credentialTypeOf(provider, configured)
})

const withSharedOAuthMethods = (
  provider: OpenCodeAuthProvider,
  configured: ReadonlyArray<string>
): Omit<OpenCodeAuthProvider, "credentialType"> & { readonly credentialType: CredentialType } => ({
  ...provider,
  methods: provider.methods.filter((method) => isSharedMethod(provider, method)),
  credentialType: credentialTypeOf(provider, configured)
})

const isSharedMethod = (provider: OpenCodeAuthProvider, method: OpenCodeAuthMethod): boolean =>
  method.type !== "oauth" || sharesSignIn("opencode", provider.id)

const credentialTypeOf = (
  provider: { readonly id: string },
  configured: ReadonlyArray<string>
): CredentialType => (configured.includes(provider.id) ? "oauth" : undefined)

const beginPiLogin = async (
  { auth, response }: SharedAccountsRoute,
  input: ProviderLogin
): Promise<boolean> => {
  if (!auth.beginPiLogin) throw oauthMethodRequired()
  if (input.methodId !== "oauth") throw oauthMethodRequired()

  writeJson(response, 201, {
    piFlow: await auth.beginPiLogin(input.providerId, "oauth", true)
  })
  return true
}

const beginOpenCodeLogin = async (
  { auth, response }: SharedAccountsRoute,
  input: ProviderLogin,
  accountId: string
): Promise<boolean> => {
  if (!auth.beginOpenCodeLogin) throw oauthMethodRequired()
  if (!input.methodId) throw oauthMethodRequired()

  writeJson(response, 201, {
    openCodeFlow: await auth.beginOpenCodeLogin(
      accountId,
      input.providerId,
      input.methodId,
      input.inputs,
      undefined,
      true
    )
  })
  return true
}

const oauthMethodRequired = (): HttpFailure => new HttpFailure(400, "Choose an OAuth method")

const providerAccounts: ReadonlyMap<string, ProviderAccounts> = new Map([
  [
    "pi",
    {
      harnessId: "pi",
      singleProfile: true,
      listProviders: listPiProviders,
      beginLogin: beginPiLogin
    }
  ],
  [
    "opencode",
    {
      harnessId: "opencode",
      singleProfile: false,
      listProviders: listOpenCodeProviders,
      beginLogin: beginOpenCodeLogin
    }
  ]
])
