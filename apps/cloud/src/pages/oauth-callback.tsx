import type { Context } from "hono"

import type { CloudEnv } from "../env.js"
import type { OAuthDelivery } from "../hub-inbox.js"
import { heading, page } from "./pages.js"

type Ctx = Context<{ Bindings: CloudEnv }>

export type OAuthPageOutcome = OAuthDelivery | "expired"

interface OAuthPageCopy {
  readonly status: 200 | 400 | 503
  readonly title: string
  readonly subtitle: string
}

export const oauthCallbackPage = (c: Ctx, outcome: OAuthPageOutcome, providerError?: string) => {
  const copy = pageCopy(outcome, providerError)
  c.status(copy.status)
  c.header("Cache-Control", "no-store")
  return page(c, copy.title, heading(copy.title, copy.subtitle))
}

const pageCopy = (outcome: OAuthPageOutcome, providerError: string | undefined): OAuthPageCopy => {
  if (providerError !== undefined && isDelivered(outcome)) return providerErrorCopy(providerError)
  return outcomeCopy[outcome]
}

const isDelivered = (outcome: OAuthPageOutcome): boolean =>
  outcome === "online" || outcome === "offline"

const providerErrorCopy = (error: string): OAuthPageCopy => ({
  status: 400,
  title: "Sign-in didn't finish",
  subtitle: `The provider returned "${error}". Return to Codevisor and try again.`
})

const outcomeCopy: Record<OAuthPageOutcome, OAuthPageCopy> = {
  online: { status: 200, title: "Signed in", subtitle: "You can return to Codevisor." },
  offline: {
    status: 200,
    title: "Signed in",
    subtitle:
      "Your machine is offline. It finishes signing in when it reconnects in the next 10 minutes."
  },
  expired: {
    status: 400,
    title: "This sign-in link has expired",
    subtitle: "Start signing in again from Codevisor."
  },
  "unknown-device": {
    status: 400,
    title: "This machine isn't connected",
    subtitle: "Reconnect the machine to Codevisor Cloud, then start signing in again."
  },
  full: {
    status: 503,
    title: "Couldn't reach your machine",
    subtitle: "Start signing in again from Codevisor in a few minutes."
  }
}
