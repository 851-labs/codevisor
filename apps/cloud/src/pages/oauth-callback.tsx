import type { Context } from "hono"

import type { CloudEnv } from "../env.js"
import { OAUTH_ITEM_TTL_MS, type OAuthDelivery } from "../hub-inbox.js"
import { heading, page } from "./pages.js"

type Ctx = Context<{ Bindings: CloudEnv }>

export type OAuthPageDelivery = OAuthDelivery | { readonly outcome: "expired" }

export interface OAuthPageOptions {
  readonly app?: string
  readonly opensApp?: boolean
  readonly error?: string
}

export const oauthCallbackPage = (
  c: Ctx,
  delivery: OAuthPageDelivery,
  options: OAuthPageOptions = {}
) => {
  const copy = pageCopy(delivery, options.error)
  c.status(copy.status)
  c.header("Cache-Control", "no-store")
  c.header("Referrer-Policy", "no-referrer")
  const link = copy.status === 200 ? appLink(options.app) : undefined
  const opens = link !== undefined && options.opensApp === true && delivery.outcome === "online"
  return page(
    c,
    copy.title,
    <>
      {heading(copy.title, copy.subtitle)}
      {link === undefined ? null : (
        <a class="text-sm text-sky-400 hover:text-sky-300" href={link}>
          Open Codevisor
        </a>
      )}
    </>,
    opens ? `location.href = ${JSON.stringify(link)}` : undefined
  )
}

interface OAuthPageCopy {
  readonly status: 200 | 400 | 503
  readonly title: string
  readonly subtitle: string
}

const pageCopy = (delivery: OAuthPageDelivery, error: string | undefined): OAuthPageCopy => {
  const machine = "machineName" in delivery ? delivery.machineName : undefined
  if (error !== undefined && isDelivered(delivery)) return providerErrorCopy(error)
  if (delivery.outcome === "online") return signedInCopy(machine)
  if (delivery.outcome === "offline") return offlineCopy(machine)
  return failureCopy[delivery.outcome]
}

const isDelivered = (delivery: OAuthPageDelivery): boolean =>
  delivery.outcome === "online" || delivery.outcome === "offline"

const signedInCopy = (machine: string | undefined): OAuthPageCopy => ({
  status: 200,
  title: "Signed in",
  subtitle: `${machine ?? "Your machine"} is finishing up. You can close this tab and return to Codevisor.`
})

const offlineCopy = (machine: string | undefined): OAuthPageCopy => ({
  status: 200,
  title: "Almost signed in",
  subtitle: `${machine ?? "The machine that started this sign-in"} is offline right now. It finishes signing in if it reconnects in the next ${OAUTH_ITEM_TTL_MS / 60_000} minutes. If it doesn't, start signing in again from Codevisor.`
})

const providerErrorCopy = (error: string): OAuthPageCopy => ({
  status: 400,
  title: "Sign-in didn't finish",
  subtitle: `The sign-in page returned "${error}". Start signing in again from Codevisor.`
})

const failureCopy: Record<"expired" | "unknown-device" | "full", OAuthPageCopy> = {
  expired: {
    status: 400,
    title: "This sign-in link has expired",
    subtitle:
      "It was already used or is more than 15 minutes old. Start signing in again from Codevisor."
  },
  "unknown-device": {
    status: 400,
    title: "This machine isn't connected",
    subtitle:
      "The machine that started this sign-in is no longer connected to your Codevisor account. Reconnect it, then start signing in again."
  },
  full: {
    status: 503,
    title: "Couldn't reach your machine",
    subtitle: "Start signing in again from Codevisor in a few minutes."
  }
}

const appLink = (app: string | undefined): string | undefined =>
  app === undefined ? undefined : `${app}://signed-in`
