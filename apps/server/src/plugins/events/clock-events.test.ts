import { describe, expect, it } from "vitest"

import { HttpFailure } from "../../server-context.js"
import { run, waitFor } from "../../test-support.js"
import { makeClockEventSource, maxClockWaitMs } from "./clock-event-source.js"
import { eventsFixture, type EventsFixture } from "./plugin-events-test-support.js"

const start = Date.parse("2026-11-13T17:10:00.000Z")
const minute = 60_000
const hour = 60 * minute

const clockFixture = async () => {
  const fixture = await eventsFixture()
  let now = start
  const clock = makeClockEventSource({ now: () => now, timeZone: "America/Los_Angeles" })
  const engine = () => fixture.engine({ builtins: [clock], now: () => now })
  return {
    ...fixture,
    engine,
    setNow: (time: number) => {
      now = time
    },
    subscribe: (events: ReturnType<typeof engine>, event: string, args: Record<string, unknown>) =>
      events.subscribe({
        sessionId: fixture.session.id,
        plugin: "clock",
        event,
        arguments: args,
        note: `${event} note`
      })
  }
}

const subscriptionsOf = (fixture: EventsFixture) =>
  run(fixture.db.listPluginEventSubscriptions(fixture.session.id))

const payloads = (fixture: EventsFixture) =>
  fixture.outbox.texts().map((text) => JSON.parse(text.split("\n")[2]!))

describe("Clock events", () => {
  it("wakes the subscriber once after a delay, then drops the subscription", async () => {
    const fixture = await clockFixture()
    const events = fixture.engine()

    const subscription = await fixture.subscribe(events, "after", { minutes: 30 })
    const waiting = await fixture.clock.nextSleep(1)
    fixture.setNow(start + 30 * minute)
    waiting.wake()
    await waitFor(async () => (await subscriptionsOf(fixture)).length === 0)

    expect(subscription).toMatchObject({
      pluginName: "Clock",
      symbolName: "clock",
      eventTitle: "After a delay",
      once: true,
      explained: "Once at Nov 13, 2026, 9:40 AM PST",
      label: "Nov 13, 9:40 AM",
      firesAt: "2026-11-13T17:40:00.000Z",
      arguments: { minutes: 30, timezone: "America/Los_Angeles", dueAt: "2026-11-13T17:40:00.000Z" }
    })
    expect(waiting.ms).toBe(maxClockWaitMs)
    expect(payloads(fixture)).toEqual([
      {
        scheduledFor: "2026-11-13T17:40:00.000Z",
        firedAt: "2026-11-13T17:40:00.000Z",
        missedRuns: 0
      }
    ])
    expect(fixture.outbox.texts()[0]).toContain(
      'plugin="Clock" pluginId="codevisor.clock" event="after" eventTitle="After a delay" label="Nov 13, 9:40 AM" symbol="clock"'
    )
  })

  it("reads a time without an offset in the given time zone and sleeps until it is due", async () => {
    const fixture = await clockFixture()
    const events = fixture.engine()

    const subscription = await fixture.subscribe(events, "at", {
      at: "2026-11-13T12:10:30",
      timezone: "America/New_York"
    })
    const waiting = await fixture.clock.nextSleep(1)

    expect(subscription.arguments.dueAt).toBe("2026-11-13T17:10:30.000Z")
    expect(subscription.explained).toBe("Once at Nov 13, 2026, 12:10 PM EST")
    expect(waiting.ms).toBe(30_000)
    expect(fixture.outbox.delivered).toEqual([])
  })

  it("fires a cron schedule once for runs missed while the server was down, then waits for the next run", async () => {
    const fixture = await clockFixture()
    const before = fixture.engine()
    const subscription = await fixture.subscribe(before, "every", { cron: "0 * * * *" })
    await fixture.clock.nextSleep(1)
    before.close()

    fixture.setNow(start + 3 * hour)
    const after = fixture.engine()
    await after.start()
    const waiting = await fixture.clock.nextSleep(2)

    expect(subscription).toMatchObject({
      once: false,
      label: "Every hour",
      explained: "Every hour (America/Los_Angeles)"
    })
    expect(payloads(fixture)).toEqual([
      {
        scheduledFor: "2026-11-13T20:00:00.000Z",
        firedAt: "2026-11-13T20:10:00.000Z",
        missedRuns: 2
      }
    ])
    expect(waiting.ms).toBe(maxClockWaitMs)

    fixture.setNow(start + 3 * hour + 10 * minute)
    waiting.wake()
    await fixture.clock.nextSleep(3)
    expect(fixture.outbox.delivered).toHaveLength(1)
  })

  it("does not count runs scheduled before the subscription", async () => {
    const fixture = await clockFixture()
    const events = fixture.engine()

    await fixture.subscribe(events, "every", { cron: "*/20 * * * * *" })
    const waiting = await fixture.clock.nextSleep(1)

    expect(waiting.ms).toBe(20_000)
    expect(fixture.outbox.delivered).toEqual([])
  })

  it.each([
    ["after", {}, "Clock: after needs a positive seconds, minutes, hours, or days"],
    ["after", { minutes: -1 }, "Clock: minutes must be a number of zero or more"],
    ["at", { at: "2026-11-13T09:00" }, 'Clock: at "2026-11-13T09:00" is in the past'],
    ["at", { at: "soon" }, 'Clock: at "soon" is not a date and time, e.g. 2026-11-14T09:00'],
    [
      "every",
      { cron: "every day" },
      'Clock: cron "every day": Invalid number of segments in cron expression'
    ],
    [
      "every",
      { cron: "0 9 * * *", timezone: "Mars/Base" },
      'Clock: timezone "Mars/Base" is not an IANA time zone, e.g. America/New_York'
    ]
  ])("refuses %s with %j", async (event, args, message) => {
    const fixture = await clockFixture()

    const refused = fixture.subscribe(fixture.engine(), event, args)

    await expect(refused).rejects.toEqual(new HttpFailure(400, message))
    expect(await subscriptionsOf(fixture)).toEqual([])
  })
})
