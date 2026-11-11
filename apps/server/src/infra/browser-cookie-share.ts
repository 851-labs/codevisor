import {
  FLEET_BROWSER_COOKIES_PATH,
  SharedBrowserCookieBatch,
  type BrowserCookieShareRequest,
  type MachineSummary,
  type SharedBrowserCookie
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { compareSyncTimestamps } from "@codevisor/sync"
import { Schema } from "effect"

import { run } from "../server-context.js"
import type { MachineLink } from "./machine-link.js"

export interface BrowserCookieShare {
  readonly shareNow: () => Promise<void>
  readonly refusesPeer: (machineId: string) => boolean
  readonly answer: (request: BrowserCookieShareRequest) => Promise<SharedBrowserCookieBatch>
  readonly start: () => void
  readonly stop: () => void
}

export interface BrowserCookieShareOptions {
  readonly db: CodevisorDatabaseService
  readonly link: Pick<MachineLink, "list" | "invoke" | "resolve">
  readonly self: { readonly id: string; readonly name: () => string }
  readonly isSandbox: () => boolean
  readonly now: () => number
  readonly log: (line: string) => void
}

export const browserCookieSharePollMs = 3_000
export const browserCookieCatchUpMs = 60_000

export const makeBrowserCookieShare = (options: BrowserCookieShareOptions): BrowserCookieShare => {
  const shareNow = async (): Promise<void> => {
    if (options.isSandbox()) return

    const peers = sharingPeers(await options.link.list())
    await Promise.all(peers.map((peer) => shareWithPeer(options, peer)))
  }
  const loop = shareLoop(options, shareNow)
  return {
    shareNow,
    refusesPeer: (machineId) => options.isSandbox() || !isSharingPeer(options, machineId),
    answer: (request) => answerPeer(options.db, request),
    start: loop.start,
    stop: loop.stop
  }
}

const maxPagesPerRound = 50
const decodeBatch = Schema.decodeUnknownSync(SharedBrowserCookieBatch)

const sharingPeers = (machines: ReadonlyArray<MachineSummary>): ReadonlyArray<MachineSummary> =>
  machines.filter((machine) => !machine.isCurrent && machine.online && !machine.ephemeral)

const isSharingPeer = (options: BrowserCookieShareOptions, machineId: string): boolean => {
  const peer = options.link.resolve(machineId)
  return peer !== undefined && peer !== "self" && peer.isSandbox !== true
}

const shareWithPeer = async (
  options: BrowserCookieShareOptions,
  peer: MachineSummary
): Promise<void> => {
  try {
    await exchangeWithPeer(options, peer.id)
  } catch (cause) {
    options.log(`Couldn't share browser cookies with ${peer.name}: ${String(cause)}`)
  }
}

const exchangeWithPeer = async (
  { db, link, self }: BrowserCookieShareOptions,
  peerId: string
): Promise<void> => {
  const origin = { machineId: self.id, machineName: self.name() }
  let cursor = await run(db.getBrowserCookiePeerCursor(peerId))
  for (let page = 0; page < maxPagesPerRound; page += 1) {
    const outgoing = await run(db.sharedBrowserCookiesAfter(cursor.sent))
    const request = { since: cursor.seen, entries: outgoing.entries }
    const incoming = decodeBatch(
      await link.invoke(peerId, FLEET_BROWSER_COOKIES_PATH, request, origin)
    )
    await run(db.mergeSharedBrowserCookies(incoming.entries))

    cursor = { sent: outgoing.revision, seen: incoming.revision }
    await run(db.setBrowserCookiePeerCursor(peerId, cursor))
    if (!outgoing.more && !incoming.more) return
  }
}

const answerPeer = async (
  db: CodevisorDatabaseService,
  request: BrowserCookieShareRequest
): Promise<SharedBrowserCookieBatch> => {
  await run(db.mergeSharedBrowserCookies(request.entries))
  const batch = await run(db.sharedBrowserCookiesAfter(request.since))
  const sent = new Map(request.entries.map((entry) => [entry.key, entry.stamp]))
  return { ...batch, entries: batch.entries.filter((entry) => !echoes(entry, sent)) }
}

const echoes = (
  entry: SharedBrowserCookie,
  sent: ReadonlyMap<string, SharedBrowserCookie["stamp"]>
): boolean => {
  const stamp = sent.get(entry.key)
  return stamp !== undefined && compareSyncTimestamps(stamp, entry.stamp) === 0
}

const shareLoop = (options: BrowserCookieShareOptions, shareNow: () => Promise<void>) => {
  let timer: ReturnType<typeof setInterval> | undefined
  let sharing = false
  let sharedRevision = -1
  let sharedAt = Number.NEGATIVE_INFINITY

  const isDue = (revision: number): boolean =>
    revision !== sharedRevision || options.now() - sharedAt >= browserCookieCatchUpMs

  const tick = async (): Promise<void> => {
    if (sharing) return

    const revision = await run(options.db.browserCookieShareRevision)
    if (!isDue(revision)) return

    sharing = true
    sharedRevision = revision
    sharedAt = options.now()
    await shareNow().finally(() => {
      sharing = false
    })
  }

  return {
    start: () => {
      if (timer !== undefined) return
      timer = setInterval(() => void tick().catch(() => undefined), browserCookieSharePollMs)
      timer.unref()
    },
    stop: () => {
      clearInterval(timer)
      timer = undefined
    }
  }
}
