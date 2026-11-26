import {
  type Cancel,
  type Clock,
  createEventStreams,
  type EventOccurrence,
  type EventsStreamParams,
  type StreamClosed,
  type StreamExtra,
  type WebhookParams
} from "@codevisor/plugin-kit"

import type { SentryAccount } from "./sentry-account.js"
import { type Fetch, sentryApi, type SentryApi, type SentryHosts } from "./sentry-api.js"
import { sentryIngress } from "./sentry-event-catalog.js"
import type { OrganizationView } from "./sentry-occurrences.js"
import { sentryPingOf } from "./sentry-ping.js"
import { pollIntervalMs, polledEvents, pollOrganization, type PollState } from "./sentry-poll.js"
import { webhookOccurrences } from "./sentry-webhook-occurrences.js"

export interface SentryFeeds {
  open(
    params: EventsStreamParams,
    account: SentryAccount,
    extra: StreamExtra
  ): Promise<StreamClosed>
  receive(params: WebhookParams, account: SentryAccount): Promise<WebhookOutcome>
}

export interface WebhookOutcome {
  [key: string]: unknown
  accepted: number
  status: number
}

export interface SentryFeedsOptions {
  fetch: Fetch
  hosts: SentryHosts
  clock: Clock
}

export const sentryStreamLifetimeMs = 60 * 60_000
export const viewsLifetimeMs = 10 * 60_000

export const createSentryFeeds = (options: SentryFeedsOptions): SentryFeeds => {
  const feeds = new Map<string, AccountFeed>()
  const streams = createEventStreams({ clock: options.clock, heartbeatCursor: () => null })
  const apiFor = (feed: AccountFeed) => sentryApi(options.fetch, options.hosts, feed.accessToken)

  const publish = (accountId: string, occurrences: ReadonlyArray<EventOccurrence>): number => {
    let delivered = 0
    for (const occurrence of occurrences)
      delivered += streams.publish(
        occurrence,
        (stream) => stream.accountId === accountId && stream.name === occurrence.name
      )
    return delivered
  }

  const reloadViews = async (feed: AccountFeed): Promise<ReadonlyArray<OrganizationView>> => {
    feed.views = await organizationViews(apiFor(feed))
    feed.viewsExpireAt = options.clock.now() + viewsLifetimeMs
    return feed.views
  }

  const currentViews = (feed: AccountFeed): Promise<ReadonlyArray<OrganizationView>> => {
    if (feed.views !== undefined && options.clock.now() < feed.viewsExpireAt)
      return Promise.resolve(feed.views)

    return reloadViews(feed)
  }

  const poll = async (feed: AccountFeed): Promise<void> => {
    const startedAt = options.clock.now()
    const api = apiFor(feed)
    const views = await currentViews(feed)
    for (const view of views)
      for (const eventName of feed.polled.keys())
        publish(feed.accountId, await pollOrganization(api, view, eventName, feed.state))
    feed.state.watermark = startedAt
  }

  const pollInTurn = (feed: AccountFeed) => {
    if (feed.polling) return
    feed.polling = true
    poll(feed)
      .catch(() => undefined)
      .finally(() => {
        feed.polling = false
      })
  }

  const join = async (account: SentryAccount, eventName: string): Promise<AccountFeed> => {
    const feed = feeds.get(account.id) ?? newFeed(account, options.clock.now())
    feed.accessToken = account.accessToken
    await reloadViews(feed)
    feeds.set(account.id, feed)
    track(feed, eventName, 1)
    feed.stopPolling ??= options.clock.every(pollIntervalMs, () => pollInTurn(feed))
    return feed
  }

  const leave = (feed: AccountFeed, eventName: string): void => {
    track(feed, eventName, -1)
    if (feed.streams > 0) return

    feed.stopPolling?.()
    feed.stopPolling = undefined
  }

  return {
    open: async (params, account, extra) => {
      const feed = await join(account, params.name)
      const opening = {
        name: params.name,
        accountId: account.id,
        position: { cursor: null, truncated: false },
        backlog: [],
        lifetimeMs: sentryStreamLifetimeMs
      }
      return streams.open(opening, extra).finally(() => leave(feed, params.name))
    },
    receive: async (params, account) => {
      if (params.ingress !== sentryIngress.name) return outcome(0, notFound)

      const ping = sentryPingOf(params.request.body)
      if (ping === undefined) return outcome(0, badRequest)

      const feed = feeds.get(account.id)
      const view = feed?.views?.find(
        (candidate) => candidate.organization.id === ping.organizationId
      )
      if (feed === undefined || feed.streams === 0 || view === undefined) return outcome(0, ok)

      feed.accessToken = account.accessToken
      return webhookOccurrences(ping, apiFor(feed), view).then(
        (occurrences) => outcome(publish(account.id, occurrences), ok),
        () => outcome(0, upstreamFailed)
      )
    }
  }
}

interface AccountFeed {
  accountId: string
  accessToken: string
  streams: number
  polled: Map<string, number>
  polling: boolean
  stopPolling: Cancel | undefined
  views: ReadonlyArray<OrganizationView> | undefined
  viewsExpireAt: number
  state: PollState
}

const track = (feed: AccountFeed, eventName: string, change: 1 | -1): void => {
  feed.streams += change
  if (!polledEvents.has(eventName)) return

  const polled = (feed.polled.get(eventName) ?? 0) + change
  if (polled > 0) feed.polled.set(eventName, polled)
  else feed.polled.delete(eventName)
}

const newFeed = (account: SentryAccount, now: number): AccountFeed => ({
  accountId: account.id,
  accessToken: account.accessToken,
  streams: 0,
  polled: new Map(),
  polling: false,
  stopPolling: undefined,
  views: undefined,
  viewsExpireAt: 0,
  state: { watermark: now, seen: new Map() }
})

export const organizationViews = async (api: SentryApi): Promise<Array<OrganizationView>> => {
  const [me, organizations] = await Promise.all([api.me(), api.organizations()])
  return Promise.all(
    organizations.map(async (organization) => ({
      organization,
      me,
      teamIds: new Set((await api.myTeams(organization).catch(() => [])).map((team) => team.id))
    }))
  )
}

const ok = 200
const badRequest = 400
const notFound = 404
const upstreamFailed = 502

const outcome = (accepted: number, status: number): WebhookOutcome => ({ accepted, status })
