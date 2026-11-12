import { accountFromMeta } from "@codevisor/plugin-kit"

export interface SlackAccount {
  id: string
  userToken: string
  signingSecret: string | undefined
}

export const slackAccount = (
  meta: Record<string, unknown> | undefined
): SlackAccount | undefined => {
  const account = accountFromMeta(meta)
  const userToken = textField(account?.fields, "userToken")
  if (account === undefined || userToken === undefined) return undefined

  return { id: account.id, userToken, signingSecret: textField(account.fields, "signingSecret") }
}

export const missingSlackAccount =
  "A connected Slack account is required. Set one up from Settings › Plugins › Slack."

export const rejectedSlackToken =
  "Slack rejected the token. Reconnect the account from Settings › Plugins › Slack."

const textField = (
  fields: Record<string, unknown> | undefined,
  key: string
): string | undefined => {
  const value = fields?.[key]
  return typeof value === "string" && value !== "" ? value : undefined
}
