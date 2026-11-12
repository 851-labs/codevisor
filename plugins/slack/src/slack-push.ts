import {
  type Clock,
  createEventStreams,
  type EventOccurrence,
  type EventsStreamParams,
  type StreamClosed,
  type StreamExtra,
  type WebhookParams
} from "@codevisor/plugin-kit"

import type { SlackAccount } from "./slack-account.js"
import { type Fetch, slackApi } from "./slack-api.js"
import { slackDirectory } from "./slack-directory.js"
import { type SlackEnvelope, slackEnvelopeOf } from "./slack-envelope.js"
import { slackIngress } from "./slack-event-catalog.js"
import { type FeedContext, occurrencesFor } from "./slack-occurrences.js"
import { verifiedSlackBody } from "./slack-signature.js"

export interface SlackPush {
  open(params: EventsStreamParams, account: SlackAccount, extra: StreamExtra): Promise<StreamClosed>
  receive(params: WebhookParams, account: SlackAccount): Promise<WebhookOutcome>
}

export interface WebhookOutcome {
  [key: string]: unknown
  accepted: number
  status: number
}

export const slackStreamLifetimeMs = 6 * 60 * 60_000

export const createSlackPush = (fetcher: Fetch, clock: Clock): SlackPush => {
  const feeds = new Map<string, AccountFeed>()
  const streams = createEventStreams({ clock, heartbeatCursor: () => null })

  const publish = (accountId: string, occurrences: ReadonlyArray<EventOccurrence>): number => {
    let delivered = 0
    for (const occurrence of occurrences)
      delivered += streams.publish(
        occurrence,
        (stream) => stream.accountId === accountId && stream.name === occurrence.name
      )
    return delivered
  }

  const deliver = (feed: AccountFeed, event: unknown, accountId: string): Promise<WebhookOutcome> =>
    occurrencesFor(event, feed.context).then(
      (occurrences) => outcome(publish(accountId, occurrences), ok),
      () => outcome(0, upstreamFailed)
    )

  return {
    open: async (params, account, extra) => {
      const directory = slackDirectory(slackApi(fetcher, account.userToken))
      const feed = joinFeed(feeds, account.id, { me: await directory.me(), directory })
      const opening = {
        name: params.name,
        accountId: account.id,
        position: { cursor: null, truncated: false },
        backlog: [],
        lifetimeMs: slackStreamLifetimeMs
      }
      return streams.open(opening, extra).finally(() => leaveFeed(feeds, feed))
    },
    receive: async (params, account) => {
      if (params.ingress !== slackIngress.name) return outcome(0, notFound)

      const envelope = verifiedEnvelope(params, account)
      if (envelope === undefined) return outcome(0, unauthorized)
      if (envelope.type === "url_verification") return outcome(0, ok)

      const feed = feeds.get(account.id)
      if (feed === undefined || envelope.team_id !== feed.context.me.teamId) return outcome(0, ok)

      return deliver(feed, envelope.event, account.id)
    }
  }
}

interface AccountFeed {
  accountId: string
  context: FeedContext
  streams: number
}

const ok = 200
const unauthorized = 401
const notFound = 404
const upstreamFailed = 502

const outcome = (accepted: number, status: number): WebhookOutcome => ({ accepted, status })

const verifiedEnvelope = (
  params: WebhookParams,
  account: SlackAccount
): SlackEnvelope | undefined => {
  if (account.signingSecret === undefined) return undefined

  const body = verifiedSlackBody(account.signingSecret, params.request)
  return body === undefined ? undefined : slackEnvelopeOf(body)
}

const joinFeed = (
  feeds: Map<string, AccountFeed>,
  accountId: string,
  context: FeedContext
): AccountFeed => {
  const feed = feeds.get(accountId) ?? { accountId, context, streams: 0 }
  feed.context = context
  feed.streams += 1
  feeds.set(accountId, feed)
  return feed
}

const leaveFeed = (feeds: Map<string, AccountFeed>, feed: AccountFeed): void => {
  feed.streams -= 1
  if (feed.streams === 0) feeds.delete(feed.accountId)
}
