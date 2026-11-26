import { describe, expect, it } from "vitest"

import { run, waitFor } from "../../test-support.js"
import {
  eventList,
  eventsFixture,
  pingPlugin,
  pingType,
  type EventsFixture
} from "./plugin-events-test-support.js"

const secondSession = (fixture: EventsFixture) =>
  run(fixture.db.createSession({ projectId: fixture.project.id, harnessId: "codex" }))

const changedSessions = () => {
  const sessions: Array<string> = []
  return { sessions, onSubscriptionsChanged: (sessionId: string) => sessions.push(sessionId) }
}

describe("plugin removed or turned off under its subscriptions", () => {
  it("tells each subscribed agent once, listing the subscriptions removal deleted", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture)
    const changed = changedSessions()
    const events = fixture.engine({ onSubscriptionsChanged: changed.onSubscriptionsChanged })
    const other = await secondSession(fixture)
    const ping = { plugin: pinger.id, event: "ping" }
    await events.subscribe({
      ...ping,
      sessionId: fixture.session.id,
      filter: 'level == "error"',
      note: "Page on errors"
    })
    await events.subscribe({
      ...ping,
      sessionId: fixture.session.id,
      arguments: { channel: "ops" },
      once: true
    })
    await events.subscribe({ ...ping, sessionId: other.id, note: "Count pings" })
    const elsewhere = await pingPlugin(fixture, "Elsewhere")
    const kept = await events.subscribe({
      sessionId: fixture.session.id,
      plugin: elsewhere.id,
      event: "ping",
      note: "Keep watching"
    })
    changed.sessions.length = 0

    const deleted = await run(fixture.db.deleteMcpServer(pinger.id))
    fixture.fake.remove(pinger.id)
    fixture.fake.changed({ kind: "removed", server: pinger, subscriptions: deleted })
    await waitFor(() => fixture.outbox.delivered.length === 2)

    expect(fixture.outbox.delivered.map((entry) => entry.subscriberId)).toEqual([
      fixture.session.id,
      other.id
    ])
    expect(fixture.outbox.delivered[0]!.event).toEqual({
      message: {
        text: [
          `<codevisor-event machine="Studio Mac" machineId="server-a" type="plugin.removed" plugin="Pinger" pluginId="${pinger.id}">`,
          "The user removed the Pinger plugin, so these subscriptions of yours were deleted and won't wake you again:",
          '- ping: "Page on errors", filter level == "error"',
          '- ping: "every event", arguments {"channel":"ops"}, once',
          "Tell the user which follow-ups stopped. To bring them back, Pinger has to be installed again (plugins.request_setup shows the user a card), then subscribe again with events.subscribe.",
          "</codevisor-event>"
        ].join("\n")
      },
      sourceSessionId: `plugin:${pinger.id}`
    })
    expect(fixture.outbox.texts()[1]).toContain('- ping: "Count pings"\n')
    expect(changed.sessions).toEqual([fixture.session.id, other.id])
    expect((await events.subscriptions()).map((subscription) => subscription.id)).toEqual([kept.id])
  })

  it("holds a turned-off plugin's subscriptions without retrying, tells the agent, and resumes them when it's back on", async () => {
    const fixture = await eventsFixture()
    const pinger = await pingPlugin(fixture, "Pinger", {
      "events/list": eventList(pingType({ delivery: ["push"] }))
    })
    const events = fixture.engine()
    const watch = await events.subscribe({
      sessionId: fixture.session.id,
      plugin: pinger.id,
      event: "ping",
      note: "Watch pings"
    })
    await waitFor(() => fixture.fake.streams.length === 1)

    fixture.fake.setEnabled(pinger.id, false)
    await waitFor(() => fixture.outbox.delivered.length === 1)
    await waitFor(() => fixture.fake.streams[0]!.signal.aborted)
    const pausedWhileOff = (await events.subscriptions())[0]?.pausedReason
    const streamsWhileOff = events.activeSources().length

    fixture.fake.setEnabled(pinger.id, true)
    await waitFor(() => fixture.fake.streams.length === 2)

    expect(fixture.outbox.texts()).toEqual([
      [
        `<codevisor-event machine="Studio Mac" machineId="server-a" type="plugin.disabled" plugin="Pinger" pluginId="${pinger.id}">`,
        "The user turned off Pinger, so these subscriptions of yours are on hold and won't wake you while it's off:",
        `- ping: "Watch pings", subscriptionId ${watch.id}`,
        "They're kept and start again on their own when Pinger is turned back on in Settings › Plugins. Tell the user which follow-ups are on hold.",
        "</codevisor-event>"
      ].join("\n")
    ])
    expect(pausedWhileOff).toBe("Pinger is turned off")
    expect(streamsWhileOff).toBe(0)
    expect((await events.subscriptions())[0]?.pausedReason).toBeUndefined()
  })
})
