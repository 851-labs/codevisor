import type { CloudEnv } from "./env.js"

export interface InboxRouteConfig {
  readonly config: Readonly<Record<string, string>> | undefined
  readonly unavailable: string
}

export const inboxRouteConfig = (env: CloudEnv, route: string): InboxRouteConfig | undefined =>
  routes.get(route)?.(env)

export const GMAIL_PUSH_OFF =
  "Gmail push is turned off on this Codevisor Cloud: GMAIL_PUSH_TOPIC isn't set"

const routes: ReadonlyMap<string, (env: CloudEnv) => InboxRouteConfig> = new Map([
  [
    "gmail",
    (env: CloudEnv) => ({
      config: env.GMAIL_PUSH_TOPIC ? { topic: env.GMAIL_PUSH_TOPIC } : undefined,
      unavailable: GMAIL_PUSH_OFF
    })
  ]
])
