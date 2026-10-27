import { accountFromMeta } from "@codevisor/plugin-kit"

export interface GmailAccount {
  id: string
  identity: string | undefined
  accessToken: string
}

export const gmailAccount = (
  meta: Record<string, unknown> | undefined
): GmailAccount | undefined => {
  const account = accountFromMeta(meta)
  if (account?.accessToken === undefined || account.accessToken === "") return undefined

  return { id: account.id, identity: account.identity, accessToken: account.accessToken }
}

export const missingGmailAccount =
  "A signed-in Google account is required. Connect one in Settings › Plugins › Gmail."
