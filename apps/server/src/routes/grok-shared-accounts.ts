import type { HarnessAccountRecord } from "@codevisor/db"

import { HttpFailure, run, writeJson } from "../server-context.js"
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

type UnsupportedGrokAction = "create" | "rename" | "inherit" | "answer" | "providers"

type GrokActionName = Exclude<SharedAccountActionName, UnsupportedGrokAction | "list">

type GrokActionHandler = (request: AccountActionRequest<GrokActionName>) => Promise<boolean>

const unsupportedGrokActions: ReadonlySet<SharedAccountActionName> = new Set([
  "create",
  "rename",
  "inherit",
  "answer",
  "providers"
])

export const routeGrokAccounts = async (accounts: SharedAccountsRoute): Promise<boolean> => {
  const input = await readSharedAccountAction(accounts.request)
  disableCaching(accounts.response)

  if (isUnsupported(input)) throw new HttpFailure(400, "Unknown Grok account action")
  if (input.action === "list") return listAccounts(accounts)

  let account: HarnessAccountRecord | undefined
  if (input.accountId) account = await run(accounts.services.db.getHarnessAccount(input.accountId))
  return routeAccountAction({
    ...accounts,
    input,
    account: requireAccountOf(account, accounts.harnessId)
  })
}

const isUnsupported = (
  input: SharedAccountAction
): input is SharedAccountAction<UnsupportedGrokAction> => unsupportedGrokActions.has(input.action)

const routeAccountAction: GrokActionHandler = (request) =>
  grokActions[request.input.action](request)

const listAccounts = async ({
  auth,
  harnessId,
  response
}: SharedAccountsRoute): Promise<boolean> => {
  writeJson(response, 200, { accounts: await auth.accounts(harnessId, true) })
  return true
}

const probeAccount: GrokActionHandler = async ({ auth, response, account }) => {
  writeJson(response, 200, { account: await auth.probeAccount(account.id, true, true) })
  return true
}

const beginLogin: GrokActionHandler = async ({ auth, response, input, account }) => {
  writeJson(response, 201, {
    flow: await auth.beginLogin(account.id, input.methodId, input.apiKey, true)
  })
  return true
}

const logoutAccount: GrokActionHandler = async ({ auth, response, account }) => {
  writeJson(response, 200, { account: await auth.logout(account.id, true) })
  return true
}

const cancelLogin: GrokActionHandler = (request) =>
  cancelSignIn(request, request.input, "Choose a sign-in attempt")

const grokActions: Record<GrokActionName, GrokActionHandler> = {
  probe: probeAccount,
  login: beginLogin,
  activate: listAccounts,
  logout: logoutAccount,
  remove: logoutAccount,
  cancel: cancelLogin
}
