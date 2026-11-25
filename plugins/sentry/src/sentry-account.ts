import { accountFromMeta } from "@codevisor/plugin-kit"

export interface SentryAccount {
  id: string
  accessToken: string
}

export const sentryAccount = (
  meta: Record<string, unknown> | undefined
): SentryAccount | undefined => {
  const account = accountFromMeta(meta)
  if (account?.accessToken === undefined || account.accessToken === "") return undefined

  return { id: account.id, accessToken: account.accessToken }
}

export const missingSentryAccount =
  "A signed-in Sentry account is required. Sign in from Settings › Plugins › Sentry."

export const rejectedSentrySignIn =
  "Sentry rejected the sign-in. Sign in again from Settings › Plugins › Sentry."
