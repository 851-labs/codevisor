import { invalidParamsError } from "@codevisor/plugin-kit"

import { rejectedSentrySignIn, sentryAccount } from "./sentry-account.js"
import { type Fetch, SentryApiError, sentryApi, type SentryHosts } from "./sentry-api.js"

export interface SentryAccountCheck {
  [key: string]: unknown
  identity?: string
  routeKeys?: Array<string>
}

export const checkSentryAccount = async (
  fetcher: Fetch,
  hosts: SentryHosts,
  meta: Record<string, unknown> | undefined
): Promise<SentryAccountCheck> => {
  const account = sentryAccount(meta)
  if (account === undefined) return {}

  const api = sentryApi(fetcher, hosts, account.accessToken)
  const [me, organizations] = await Promise.all([api.me(), api.organizations()]).catch(
    rejectedAsInvalid
  )
  return {
    identity: me.email || me.name,
    routeKeys: organizations.map((organization) => organization.id)
  }
}

const rejectedAsInvalid = (error: unknown): never => {
  if (error instanceof SentryApiError && error.status === unauthorized)
    throw invalidParamsError(rejectedSentrySignIn)
  throw error
}

const unauthorized = 401
