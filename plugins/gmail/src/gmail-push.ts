import {
  type Clock,
  createEventStreams,
  type EventsStreamParams,
  type StreamClosed,
  type StreamExtra,
  type WebhookParams
} from "@codevisor/plugin-kit"

import type { GmailAccount } from "./gmail-account.js"
import { type Fetch, gmailApi, type GmailApi, type GmailMessage } from "./gmail-api.js"
import { gmailIngress } from "./gmail-event-catalog.js"
import { incomingSince, receivedOccurrence } from "./gmail-history.js"
import { type GmailNotification, gmailNotificationOf } from "./gmail-push-notification.js"

export interface GmailPush {
  open(
    params: EventsStreamParams,
    account: GmailAccount,
    topic: string,
    extra: StreamExtra
  ): Promise<StreamClosed>
  receive(params: WebhookParams, account: GmailAccount): Promise<WebhookOutcome>
  remove(account: GmailAccount): Promise<void>
}

export interface WebhookOutcome {
  [key: string]: unknown
  accepted: number
  status: number
}

export const gmailStreamLifetimeMs = 6 * 60 * 60_000

export const createGmailPush = (fetcher: Fetch, clock: Clock): GmailPush => {
  const feeds = new Map<string, AccountFeed>()
  const streams = createEventStreams({
    clock,
    heartbeatCursor: (stream) => feeds.get(String(stream.accountId))!.cursor
  })

  const publish = (feed: AccountFeed, messages: ReadonlyArray<GmailMessage>): number => {
    for (const message of messages)
      streams.publish(
        receivedOccurrence(message, feed.cursor),
        (stream) => stream.accountId === feed.accountId
      )
    return messages.length
  }

  const drain = async (
    feed: AccountFeed,
    api: GmailApi,
    identity: string | undefined
  ): Promise<number> => {
    const caughtUp = await incomingSince(api, identity, feed.cursor)
    feed.cursor = caughtUp.cursor
    return publish(feed, caughtUp.messages)
  }

  return {
    open: async (params, account, topic, extra) => {
      const api = gmailApi(fetcher, account.accessToken)
      await api.watch(topic)
      const caughtUp = await incomingSince(api, account.identity, params.cursor)
      const feed = joinFeed(feeds, account.id, caughtUp.cursor)
      const backlog = caughtUp.messages.map((message) =>
        receivedOccurrence(message, caughtUp.cursor)
      )
      const opening = {
        name: params.name,
        accountId: account.id,
        position: { cursor: caughtUp.cursor, truncated: caughtUp.truncated },
        backlog,
        lifetimeMs: gmailStreamLifetimeMs
      }
      return streams.open(opening, extra).finally(() => leaveFeed(feeds, feed))
    },
    receive: async (params, account) => {
      if (params.ingress !== gmailIngress.name) return outcome(0, notFound)

      const notification = gmailNotificationOf(params.request.body)
      if (notification === undefined) return outcome(0, badRequest)

      const feed = feeds.get(account.id)
      if (feed === undefined || !notifies(notification, account)) return outcome(0, ok)
      if (!newerThan(notification.historyId, feed.cursor)) return outcome(0, ok)

      const api = gmailApi(fetcher, account.accessToken)
      const run = feed.work.then(() => drain(feed, api, account.identity))
      feed.work = run.then(
        () => undefined,
        () => undefined
      )
      return run.then(
        (accepted) => outcome(accepted, ok),
        () => outcome(0, upstreamFailed)
      )
    },
    remove: async (account) => {
      await gmailApi(fetcher, account.accessToken)
        .stop()
        .catch(() => undefined)
    }
  }
}

interface AccountFeed {
  accountId: string
  cursor: string
  streams: number
  work: Promise<void>
}

const ok = 200
const badRequest = 400
const notFound = 404
const upstreamFailed = 502

const notifies = (notification: GmailNotification, account: GmailAccount): boolean =>
  notification.emailAddress.toLowerCase() === account.identity?.toLowerCase()

const newerThan = (historyId: string, cursor: string): boolean => BigInt(historyId) > BigInt(cursor)

const outcome = (accepted: number, status: number): WebhookOutcome => ({ accepted, status })

const joinFeed = (
  feeds: Map<string, AccountFeed>,
  accountId: string,
  cursor: string
): AccountFeed => {
  const feed = feeds.get(accountId) ?? {
    accountId,
    cursor,
    streams: 0,
    work: Promise.resolve()
  }
  feed.streams += 1
  feeds.set(accountId, feed)
  return feed
}

const leaveFeed = (feeds: Map<string, AccountFeed>, feed: AccountFeed): void => {
  feed.streams -= 1
  if (feed.streams === 0) feeds.delete(feed.accountId)
}
