import { describe, expect, it } from "vitest"

import {
  connectSlack,
  dana,
  deliver,
  eng,
  eventCallback,
  incidents,
  openSlackStream,
  receivedAt,
  sam,
  samDm,
  signedWebhook
} from "./slack-test-support.js"

const message = (overrides: Record<string, unknown> = {}) => ({
  type: "message",
  channel: eng.id,
  channel_type: "channel",
  user: sam.id,
  text: "Deploy is green",
  ts: "1731350000.000100",
  ...overrides
})

const eventsFor = async (name: string, event: Record<string, unknown>) => {
  const connected = await connectSlack()
  const stream = await openSlackStream(connected, name)
  const outcome = await deliver(connected, signedWebhook(eventCallback(event)))
  return { outcome, events: connected.inbox.forSubscription(stream.subscriptionId).filter(isEvent) }
}

const isEvent = (notification: { method: string }) =>
  notification.method === "notifications/events/event"

describe("Slack events", () => {
  it("relays a message with its channel and author names", async () => {
    const { outcome, events } = await eventsFor("message.posted", message())

    expect(outcome).toEqual({ accepted: 1, status: 200 })
    expect(events[0]?.params).toMatchObject({
      eventId: `message.posted:${eng.id}:1731350000.000100`,
      name: "message.posted",
      timestamp: "2024-11-11T18:33:20.000Z",
      data: {
        text: "Deploy is green",
        ts: "1731350000.000100",
        threadTs: null,
        link: "https://acme.slack.com/archives/C0ENG000001/p1731350000000100",
        channel: { id: eng.id, name: "eng", type: "public" },
        author: { id: sam.id, name: "Sam" },
        bot: false,
        mentionsMe: false,
        isReply: false,
        inMyThread: false
      }
    })
  })

  it("wakes mention subscribers only when someone mentions the user", async () => {
    const mentioned = await eventsFor(
      "mention.created",
      message({ text: `Can you look <@${dana.id}>?` })
    )
    const plain = await eventsFor("mention.created", message())

    expect(mentioned.events.map((event) => event.params?.data)).toMatchObject([
      { mentionsMe: true }
    ])
    expect([plain.outcome, plain.events]).toEqual([{ accepted: 0, status: 200 }, []])
  })

  it("treats DMs and group DMs as direct messages", async () => {
    const dm = await eventsFor("dm.received", message({ channel: samDm.id, channel_type: "im" }))
    const channel = await eventsFor("dm.received", message())

    expect(dm.events[0]?.params?.data).toMatchObject({
      channel: { id: samDm.id, name: "Sam", type: "dm" }
    })
    expect(channel.events).toEqual([])
  })

  it("relays replies in the user's own threads", async () => {
    const reply = message({
      ts: "1731350009.000100",
      thread_ts: "1731350000.000100",
      parent_user_id: dana.id
    })
    const elsewhere = message({
      ts: "1731350009.000100",
      thread_ts: "1731350000.000100",
      parent_user_id: sam.id
    })

    const mine = await eventsFor("thread.replied", reply)
    const theirs = await eventsFor("thread.replied", elsewhere)

    expect(mine.events[0]?.params?.data).toMatchObject({
      isReply: true,
      inMyThread: true,
      link: "https://acme.slack.com/archives/C0ENG000001/p1731350009000100?thread_ts=1731350000.000100&cid=C0ENG000001"
    })
    expect(theirs.events).toEqual([])
  })

  it("never relays the user's own messages, edits or joins", async () => {
    const own = await eventsFor("message.posted", message({ user: dana.id }))
    const edit = await eventsFor("message.posted", message({ subtype: "message_changed" }))
    const join = await eventsFor("message.posted", message({ subtype: "channel_join" }))

    expect([own.events, edit.events, join.events]).toEqual([[], [], []])
  })

  it("marks bot messages", async () => {
    const { events } = await eventsFor(
      "message.posted",
      message({ user: undefined, bot_id: "B0DEPLOY001", subtype: "bot_message" })
    )

    expect(events[0]?.params?.data).toMatchObject({
      bot: true,
      author: { id: "B0DEPLOY001", name: null }
    })
  })

  it("relays reactions to the user's messages from other people", async () => {
    const reaction = {
      type: "reaction_added",
      user: sam.id,
      reaction: "white_check_mark",
      item_user: dana.id,
      item: { type: "message", channel: incidents.id, ts: "1731350000.000100" }
    }

    const mine = await eventsFor("reaction.added", reaction)
    const theirs = await eventsFor("reaction.added", { ...reaction, item_user: sam.id })

    expect(mine.events[0]?.params).toMatchObject({
      eventId: `reaction.added:${incidents.id}:1731350000.000100:${sam.id}:white_check_mark`,
      data: {
        reaction: "white_check_mark",
        ts: "1731350000.000100",
        channel: { id: incidents.id, name: "incidents", type: "public" },
        author: { id: sam.id, name: "Sam" }
      }
    })
    expect(theirs.events).toEqual([])
  })
})

describe("Slack webhook verification", () => {
  it("rejects a request signed with another secret", async () => {
    const connected = await connectSlack()
    await openSlackStream(connected, "message.posted")

    const forged = signedWebhook(eventCallback(message()), { secret: "f".repeat(32) })

    expect(await deliver(connected, forged)).toEqual({ accepted: 0, status: 401 })
  })

  it("rejects a request signed long before the cloud received it", async () => {
    const connected = await connectSlack()
    await openSlackStream(connected, "message.posted")
    const signedAt = Date.parse(receivedAt) / 1000 - 301

    const replayed = signedWebhook(eventCallback(message()), { timestamp: signedAt })

    expect(await deliver(connected, replayed)).toEqual({ accepted: 0, status: 401 })
  })

  it("accepts a delivery that waited in the inbox while the Mac slept", async () => {
    const connected = await connectSlack()
    await openSlackStream(connected, "message.posted")

    const caughtUp = signedWebhook(eventCallback(message()), { receivedAt })

    expect(await deliver(connected, caughtUp)).toEqual({ accepted: 1, status: 200 })
  })

  it("ignores events from another workspace and Slack's URL check", async () => {
    const connected = await connectSlack()
    await openSlackStream(connected, "message.posted")

    const otherTeam = await deliver(
      connected,
      signedWebhook(eventCallback(message(), "T0OTHER0001"))
    )
    const verification = await deliver(
      connected,
      signedWebhook({ type: "url_verification", challenge: "c" })
    )

    expect([otherTeam, verification]).toEqual([
      { accepted: 0, status: 200 },
      { accepted: 0, status: 200 }
    ])
  })
})
