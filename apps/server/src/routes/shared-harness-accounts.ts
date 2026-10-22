import type { HarnessAccountRecord } from "@codevisor/db"
import type { SharedOAuthHarness } from "@codevisor/harness-manager"

import { sharedHarness } from "../infra/shared-account-store.js"
import { HttpFailure, run, writeJson } from "../server-context.js"
import { routeGrokAccounts } from "./grok-shared-accounts.js"
import { providerAccountsFor, routeProviderAccounts } from "./provider-shared-accounts.js"
import { methodRouteId, rejectSyncThrows } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import {
  cancelSignIn,
  disableCaching,
  readSharedAccountAction,
  requireAccountOf
} from "./shared-account-actions.js"
import type {
  AccountActionRequest,
  SharedAccountAction,
  SharedAccountActionName,
  SharedAccountsRoute
} from "./shared-account-actions.js"

type SyncedActionName = Exclude<SharedAccountActionName, "list" | "create" | "inherit">

type SyncedActionHandler = (request: AccountActionRequest<SyncedActionName>) => Promise<boolean>

export const routeSharedHarnessAccounts = (route: RouteContext): Promise<boolean> =>
  rejectSyncThrows(() => dispatchSharedAccounts(route))

const dispatchSharedAccounts = (route: RouteContext): Promise<boolean> => {
  const harnessId = methodRouteId(route, "POST", "/v1/harnesses/:id/shared-accounts")
  if (harnessId === undefined) return Promise.resolve(false)

  const accounts = sharedAccountsRoute(route, harnessId)
  if (harnessId === "grok-build") return routeGrokAccounts(accounts)

  const provider = providerAccountsFor(harnessId)
  if (provider !== undefined) return routeProviderAccounts(accounts, provider)
  return routeSyncedAccounts(accounts)
}

const sharedAccountsRoute = (
  { services, request, response }: RouteContext,
  harnessId: string
): SharedAccountsRoute => {
  const { sharedAccounts, auth } = services
  if (!sharedAccounts) throw syncUnavailable()
  if (!auth) throw syncUnavailable()
  return { services, request, response, harnessId, shared: sharedAccounts, auth }
}

const syncUnavailable = (): HttpFailure =>
  new HttpFailure(501, "Update this machine to sync accounts")

const routeSyncedAccounts = async (accounts: SharedAccountsRoute): Promise<boolean> => {
  const input = await readSharedAccountAction(accounts.request)
  disableCaching(accounts.response)

  if (!sharedHarness(accounts.harnessId)) {
    throw new HttpFailure(400, "This harness uses provider-specific account settings")
  }
  if (input.action === "list") return listAccounts(accounts)
  if (input.action === "create") return createAccount(accounts, accounts.harnessId, input)
  if (input.action === "inherit") return inheritAccounts(accounts)

  const id = input.accountId
  let account: HarnessAccountRecord | undefined
  if (id) account = await run(accounts.services.db.getHarnessAccount(id))
  return routeAccountAction({
    ...accounts,
    input,
    account: requireAccountOf(account, accounts.harnessId)
  })
}

const routeAccountAction: SyncedActionHandler = (request) =>
  syncedActions[request.input.action](request)

const listAccounts = async ({
  shared,
  harnessId,
  response
}: SharedAccountsRoute): Promise<boolean> => {
  writeJson(response, 200, { accounts: await shared.accounts(harnessId, true) })
  return true
}

const createAccount = async (
  { shared, response }: SharedAccountsRoute,
  harnessId: SharedOAuthHarness,
  input: SharedAccountAction
): Promise<boolean> => {
  writeJson(response, 201, { account: await shared.create(harnessId, input.label) })
  return true
}

const inheritAccounts = async ({
  shared,
  harnessId,
  response
}: SharedAccountsRoute): Promise<boolean> => {
  await shared.inherit(harnessId)
  writeJson(response, 200, { accounts: await shared.accounts(harnessId) })
  return true
}

const activateAccount: SyncedActionHandler = async ({ shared, harnessId, response, account }) => {
  if (!(await shared.activate(harnessId, account.id, true))) {
    throw new HttpFailure(404, "Shared account not found")
  }

  writeJson(response, 200, { accounts: await shared.accounts(harnessId, true) })
  return true
}

const renameAccount: SyncedActionHandler = async ({ shared, response, input, account }) => {
  if (!input.label?.trim()) throw new HttpFailure(400, "Enter an account name")

  writeJson(response, 200, { account: await shared.rename(account.id, input.label) })
  return true
}

const logoutAccount: SyncedActionHandler = async ({ shared, response, account }) => {
  writeJson(response, 200, { account: await shared.logout(account.id, true) })
  return true
}

const probeAccount: SyncedActionHandler = async ({ shared, response, account }) => {
  writeJson(response, 200, { account: await shared.probe(account.id, true) })
  return true
}

const signIn: SyncedActionHandler = (request) => {
  if (request.input.methodId === "apiKey") return saveApiKey(request)
  return beginLogin(request)
}

const saveApiKey: SyncedActionHandler = async ({ shared, response, input, account }) => {
  await shared.saveApiKey(account.id, input.apiKey ?? "")
  writeJson(response, 200, {
    flow: { id: account.id, accountId: account.id, kind: "complete" }
  })
  return true
}

const beginLogin: SyncedActionHandler = async ({ auth, response, input, account }) => {
  writeJson(response, 201, {
    flow: await auth.beginLogin(account.id, input.methodId, input.apiKey)
  })
  return true
}

const answerSignIn: SyncedActionHandler = async ({ auth, response, input }) => {
  if (!input.flowId) throw signInCodeRequired()
  if (!input.code) throw signInCodeRequired()

  writeJson(response, 200, { flow: await auth.answerLogin(input.flowId, input.code) })
  return true
}

const cancelLogin: SyncedActionHandler = (request) =>
  cancelSignIn(request, request.input, "Sign-in not found")

const refuseProviders: SyncedActionHandler = () => {
  throw new HttpFailure(400, "This harness has account settings")
}

const signInCodeRequired = (): HttpFailure => new HttpFailure(400, "Enter the sign-in code")

const syncedActions: Record<SyncedActionName, SyncedActionHandler> = {
  activate: activateAccount,
  rename: renameAccount,
  remove: logoutAccount,
  logout: logoutAccount,
  probe: probeAccount,
  login: signIn,
  answer: answerSignIn,
  cancel: cancelLogin,
  providers: refuseProviders
}
