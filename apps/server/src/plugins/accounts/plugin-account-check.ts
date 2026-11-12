import { HttpFailure } from "../../server-context.js"
import { field } from "../../unknown-values.js"
import type { AccountCheck, AccountContext } from "./plugin-accounts.js"

export const accountCheckMethod = "codevisor/account/check"
export const accountCheckTimeoutMs = 20_000

export interface AccountCheckConnection {
  readonly request: (
    method: string,
    params: Record<string, unknown>,
    options: { readonly meta: Record<string, unknown>; readonly timeoutMs: number }
  ) => Promise<Record<string, unknown>>
}

export type AccountCheckConnections = (serverId: string) => Promise<AccountCheckConnection>

export const checkPluginAccount = async (
  connect: AccountCheckConnections,
  serverId: string,
  account: AccountContext
): Promise<AccountCheck | undefined> => {
  const connection = await connect(serverId).catch(() => undefined)
  if (connection === undefined) return undefined

  const reply = await connection
    .request(
      accountCheckMethod,
      {},
      { meta: accountMeta(account), timeoutMs: accountCheckTimeoutMs }
    )
    .catch(rejectedOrUnchecked)
  return reply === undefined ? undefined : accountCheckOf(reply)
}

const accountMetaKey = "dev.codevisor/account"

const accountMeta = (account: AccountContext): Record<string, unknown> => ({
  [accountMetaKey]: account
})

const rejectedOrUnchecked = (cause: unknown): undefined => {
  if (field(cause, "code") !== invalidParamsCode) return undefined

  throw new HttpFailure(
    400,
    cause instanceof Error ? cause.message : "The plugin rejected this account"
  )
}

const invalidParamsCode = -32602

const accountCheckOf = (reply: Record<string, unknown>): AccountCheck => ({
  ...textField(reply, "identity"),
  ...textField(reply, "label")
})

const textField = (reply: Record<string, unknown>, key: "identity" | "label") => {
  const value = reply[key]
  return typeof value === "string" && value !== "" ? { [key]: value } : {}
}
