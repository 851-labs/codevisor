import { accountFromMeta } from "@codevisor/plugin-kit"

export interface LinearAccount {
  id: string
  accessToken: string
}

export const linearAccount = (
  meta: Record<string, unknown> | undefined
): LinearAccount | undefined => {
  const account = accountFromMeta(meta)
  if (account?.accessToken === undefined || account.accessToken === "") return undefined

  return { id: account.id, accessToken: account.accessToken }
}

export const missingLinearAccount =
  "A signed-in Linear account is required. Sign in from Settings › Plugins › Linear."

export const rejectedLinearSignIn =
  "Linear rejected the sign-in. Sign in again from Settings › Plugins › Linear."
