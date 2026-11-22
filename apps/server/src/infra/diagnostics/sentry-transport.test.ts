import { describe, expect, it } from "vitest"

import { buildSentryEvent } from "./sentry-event.js"
import { parseSentryDsn, sentryEnvelopeSender } from "./sentry-transport.js"

const dsnText = "https://publickey@o1.ingest.us.sentry.io/42"

describe("sentry transport", () => {
  it("rejects DSNs it can't send to", () => {
    expect(parseSentryDsn("not a url")).toBeUndefined()
    expect(parseSentryDsn("http://key@example.com/1")).toBeUndefined()
    expect(parseSentryDsn("https://example.com/1")).toBeUndefined()
  })

  it("posts the event as an authenticated envelope", async () => {
    const dsn = parseSentryDsn(dsnText)!
    const requests: Request[] = []
    const send = sentryEnvelopeSender(dsn, async (url, init) => {
      requests.push(new Request(url, init))
      return new Response(null, { status: 200 })
    })
    const event = buildSentryEvent(
      new Error("boom"),
      { component: "http" },
      { release: "r", environment: "production", tags: {} },
      0
    )

    await send(event)

    const [request] = requests
    expect(request?.url).toBe("https://o1.ingest.us.sentry.io/api/42/envelope/")
    expect(request?.headers.get("x-sentry-auth")).toContain("sentry_key=publickey")
    const [header, item, body] = (await request!.text()).split("\n")
    expect(JSON.parse(header!)).toMatchObject({ event_id: event.event_id, dsn: dsnText })
    expect(JSON.parse(item!)).toEqual({ type: "event" })
    expect(JSON.parse(body!)).toMatchObject({ event_id: event.event_id, platform: "node" })
  })
})
