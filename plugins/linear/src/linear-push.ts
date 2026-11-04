import {
  type Clock,
  createEventStreams,
  type EventOccurrence,
  type EventsStreamParams,
  type StreamClosed,
  type StreamExtra,
  type WebhookParams
} from "@codevisor/plugin-kit"

import type { LinearAccount } from "./linear-account.js"
import { type Fetch, linearApi, type LinearViewer } from "./linear-api.js"
import { linearIngress } from "./linear-event-catalog.js"
import { occurrencesFor } from "./linear-occurrences.js"
import { type LinearPing, linearPingOf } from "./linear-ping.js"

export interface LinearPush {
  open(
    params: EventsStreamParams,
    account: LinearAccount,
    extra: StreamExtra
  ): Promise<StreamClosed>
  receive(params: WebhookParams, account: LinearAccount): Promise<WebhookOutcome>
  remove(account: LinearAccount): Promise<void>
}

export interface WebhookOutcome {
  [key: string]: unknown
  accepted: number
  status: number
}

export const linearStreamLifetimeMs = 6 * 60 * 60_000

export const createLinearPush = (fetcher: Fetch, clock: Clock): LinearPush => {
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

  const deliver = async (feed: AccountFeed, ping: LinearPing, account: LinearAccount) => {
    const occurrences = await occurrencesFor(
      ping,
      linearApi(fetcher, account.accessToken),
      feed.viewer
    )
    return publish(account.id, occurrences)
  }

  return {
    open: async (params, account, extra) => {
      const viewer = await linearApi(fetcher, account.accessToken).viewer()
      const feed = joinFeed(feeds, account.id, viewer)
      const opening = {
        name: params.name,
        accountId: account.id,
        position: { cursor: null, truncated: false },
        backlog: [],
        lifetimeMs: linearStreamLifetimeMs
      }
      return streams.open(opening, extra).finally(() => leaveFeed(feeds, feed))
    },
    receive: async (params, account) => {
      if (params.ingress !== linearIngress.name) return outcome(0, notFound)

      const ping = linearPingOf(params.request.body)
      if (ping === undefined) return outcome(0, badRequest)

      const feed = feeds.get(account.id)
      if (feed === undefined || !fromWorkspace(ping, feed.viewer)) return outcome(0, ok)

      return deliver(feed, ping, account).then(
        (accepted) => outcome(accepted, ok),
        () => outcome(0, upstreamFailed)
      )
    },
    remove: async (account) => {
      await linearApi(fetcher, account.accessToken)
        .revoke()
        .catch(() => undefined)
    }
  }
}

interface AccountFeed {
  accountId: string
  viewer: LinearViewer
  streams: number
}

const ok = 200
const badRequest = 400
const notFound = 404
const upstreamFailed = 502

const fromWorkspace = (ping: LinearPing, viewer: LinearViewer): boolean =>
  ping.organizationId === viewer.organization.id

const outcome = (accepted: number, status: number): WebhookOutcome => ({ accepted, status })

const joinFeed = (
  feeds: Map<string, AccountFeed>,
  accountId: string,
  viewer: LinearViewer
): AccountFeed => {
  const feed = feeds.get(accountId) ?? { accountId, viewer, streams: 0 }
  feed.viewer = viewer
  feed.streams += 1
  feeds.set(accountId, feed)
  return feed
}

const leaveFeed = (feeds: Map<string, AccountFeed>, feed: AccountFeed): void => {
  feed.streams -= 1
  if (feed.streams === 0) feeds.delete(feed.accountId)
}
