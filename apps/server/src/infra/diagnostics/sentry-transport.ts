import type { SentryEvent } from "./sentry-event.js"

export type SendSentryEvent = (event: SentryEvent) => Promise<void>

export interface SentryDsn {
  readonly envelopeUrl: string
  readonly publicKey: string
  readonly raw: string
}

export const parseSentryDsn = (dsn: string): SentryDsn | undefined => {
  const url = URL.parse(dsn)
  const projectId = url?.pathname.split("/").findLast((part) => part !== "")
  if (url === null || url.protocol !== "https:" || url.username === "" || projectId === undefined) {
    return undefined
  }
  return {
    envelopeUrl: `${url.origin}/api/${projectId}/envelope/`,
    publicKey: url.username,
    raw: dsn
  }
}

export const sentryEnvelopeSender =
  (dsn: SentryDsn, request: typeof fetch = fetch): SendSentryEvent =>
  async (event) => {
    await request(dsn.envelopeUrl, {
      method: "POST",
      headers: {
        "content-type": "application/x-sentry-envelope",
        "x-sentry-auth": `Sentry sentry_version=7, sentry_key=${dsn.publicKey}, sentry_client=${sentryClient}`
      },
      body: envelope(dsn, event),
      signal: AbortSignal.timeout(sendTimeoutMs)
    })
  }

const sentryClient = "codevisor-server/1"
const sendTimeoutMs = 10_000

const envelope = (dsn: SentryDsn, event: SentryEvent): string =>
  [
    JSON.stringify({ event_id: event.event_id, sent_at: new Date().toISOString(), dsn: dsn.raw }),
    JSON.stringify({ type: "event" }),
    JSON.stringify(event)
  ].join("\n")
