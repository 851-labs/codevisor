import { accountFromMeta, invalidParamsError } from "@codevisor/plugin-kit"

import { identityReply } from "./slack-api-schemas.js"
import { type Fetch, rejectsToken, slackApi, SlackApiError } from "./slack-api.js"

export interface CheckedSlackAccount {
  [key: string]: unknown
  label: string
}

export const requiredUserScopes = [
  "channels:history",
  "channels:read",
  "chat:write",
  "files:read",
  "files:write",
  "groups:history",
  "groups:read",
  "im:history",
  "im:read",
  "im:write",
  "mpim:history",
  "mpim:read",
  "reactions:read",
  "reactions:write",
  "search:read",
  "users:read",
  "users:read.email"
]

export const checkSlackAccount = async (
  fetcher: Fetch,
  meta: Record<string, unknown> | undefined
): Promise<CheckedSlackAccount> => {
  const fields = accountFromMeta(meta)?.fields ?? {}
  const token = requireUserToken(fields.userToken)
  requireSigningSecret(fields.signingSecret)

  const reply = await slackApi(fetcher, token).callWithScopes("auth.test").catch(rejectedCheck)
  requireScopes(reply.scopes)

  const me = identityReply.parse(reply.body)
  return { label: me.team }
}

const requireUserToken = (value: unknown): string => {
  const token = typeof value === "string" ? value.trim() : ""
  if (token.startsWith(userTokenPrefix)) return token

  throw invalidParamsError(
    tokenHints.find(([prefix]) => token.startsWith(prefix))?.[1] ?? notAUserToken
  )
}

const userTokenPrefix = "xoxp-"

const notAUserToken =
  "That doesn't look like a User OAuth Token. In your app’s settings on api.slack.com/apps, copy it from OAuth & Permissions; it starts with xoxp-."

const tokenHints: ReadonlyArray<readonly [string, string]> = [
  [
    "xoxb-",
    "That's the Bot User OAuth Token. Copy the User OAuth Token instead; it starts with xoxp-."
  ],
  [
    "xapp-",
    "That's an app-level token. Copy the User OAuth Token from OAuth & Permissions instead; it starts with xoxp-."
  ],
  [
    "xoxe",
    "That's a configuration token. Copy the User OAuth Token from OAuth & Permissions instead; it starts with xoxp-."
  ]
]

const requireSigningSecret = (value: unknown): void => {
  if (typeof value === "string" && signingSecretPattern.test(value.trim())) return

  throw invalidParamsError(
    "That doesn't look like a Signing Secret. In your app’s settings, open Basic Information and copy the Signing Secret under App Credentials: it's 32 letters and numbers."
  )
}

const signingSecretPattern = /^[0-9a-f]{32}$/i

const rejectedCheck = (error: unknown): never => {
  if (error instanceof SlackApiError && rejectsToken(error)) throw invalidParamsError(tokenRejected)
  if (error instanceof SlackApiError) throw invalidParamsError(error.message)

  throw invalidParamsError(
    `Couldn't reach Slack to check the token: ${error instanceof Error ? error.message : String(error)}`
  )
}

const tokenRejected =
  "Slack didn't accept that token. Copy the User OAuth Token again from OAuth & Permissions in your app’s settings."

const requireScopes = (granted: ReadonlyArray<string>): void => {
  const missing = requiredUserScopes.filter((scope) => !granted.includes(scope))
  if (missing.length === 0) return

  throw invalidParamsError(
    `Your Slack app is missing ${missing.join(", ")}. Create it again with Create Slack App, or add those User Token Scopes under OAuth & Permissions and reinstall it.`
  )
}
