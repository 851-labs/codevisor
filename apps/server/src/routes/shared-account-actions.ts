import type { IncomingMessage, ServerResponse } from "node:http"

import type { HarnessAccountRecord } from "@codevisor/db"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import { Schema } from "effect"

import type { SharedAccounts } from "../infra/shared-accounts.js"
import { HttpFailure, readSchema, writeJson } from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"

export interface SharedAccountsRoute {
  readonly services: CodevisorServerServices
  readonly request: IncomingMessage
  readonly response: ServerResponse
  readonly harnessId: string
  readonly shared: SharedAccounts
  readonly auth: HarnessAuthManager
}

const SharedAccountActionSchema = Schema.Struct({
  action: Schema.Literals([
    "list",
    "create",
    "rename",
    "remove",
    "activate",
    "probe",
    "login",
    "answer",
    "cancel",
    "logout",
    "inherit",
    "providers"
  ]),
  accountId: Schema.optional(Schema.String),
  label: Schema.optional(Schema.String),
  methodId: Schema.optional(Schema.String),
  apiKey: Schema.optional(Schema.String),
  flowId: Schema.optional(Schema.String),
  code: Schema.optional(Schema.String),
  providerId: Schema.optional(Schema.String),
  inputs: Schema.optional(Schema.Record(Schema.String, Schema.String))
})

type SharedAccountActionFields = typeof SharedAccountActionSchema.Type

export type SharedAccountActionName = SharedAccountActionFields["action"]

export type SharedAccountAction<A extends SharedAccountActionName = SharedAccountActionName> =
  A extends SharedAccountActionName
    ? Omit<SharedAccountActionFields, "action"> & { readonly action: A }
    : never

export interface AccountActionRequest<
  A extends SharedAccountActionName
> extends SharedAccountsRoute {
  readonly input: SharedAccountAction<A>
  readonly account: HarnessAccountRecord
}

export const readSharedAccountAction = (request: IncomingMessage): Promise<SharedAccountAction> =>
  readSchema(request, SharedAccountActionSchema)

export const disableCaching = (response: ServerResponse): void => {
  response.setHeader("Cache-Control", "no-store")
}

export const requireAccountOf = (
  account: HarnessAccountRecord | undefined,
  harnessId: string
): HarnessAccountRecord => {
  if (!account || account.harnessId !== harnessId) throw new HttpFailure(404, "Account not found")
  return account
}

export const cancelSignIn = async (
  { auth, response }: SharedAccountsRoute,
  input: SharedAccountAction,
  missingFlow: string
): Promise<boolean> => {
  if (!input.flowId) throw new HttpFailure(400, missingFlow)

  await auth.cancelLogin(input.flowId)
  writeJson(response, 200, {})
  return true
}
