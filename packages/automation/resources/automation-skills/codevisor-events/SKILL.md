---
name: codevisor-events
description: Use when you need to do something later, on a schedule, or when something happens, such as waking yourself after a delay or at a set time, running a recurring routine or cron, checking back on something, or reacting to a plugin event like a Slack message or a new Linear issue. Use it instead of a harness's built-in scheduling (CronCreate, ScheduleWakeup, /loop) or a sleep loop.
---

# Codevisor events

A subscription wakes **you, in this chat**, when its event happens. The event arrives as a hidden `<codevisor-event type="plugin.event">` message: it starts a new turn when you're idle, or waits for the end of your current turn. Subscriptions survive restarts. Several events that pile up while you're busy or offline arrive together in one turn.

Only subscribe when the user asked for the follow-up or the task needs it. Each subscription shows in the chat's inspector under Automations.

## Time: the built-in Clock

```js
// Once, after a delay (seconds, minutes, hours, days add up)
await events.subscribe({
  plugin: "clock",
  event: "after",
  arguments: { minutes: 30 },
  note: "Check the deploy finished"
})

// Once, at a time. Without Z or an offset it's read in timezone (default: this machine's)
await events.subscribe({
  plugin: "clock",
  event: "at",
  arguments: { at: "2026-11-14T09:00", timezone: "America/New_York" },
  note: "Post the release notes"
})

// Recurring, until you unsubscribe
await events.subscribe({
  plugin: "clock",
  event: "every",
  arguments: { cron: "0 9 * * 1-5" },
  note: "Triage new issues every weekday at 9"
})
```

- `after` and `at` fire once and then remove themselves.
- `every` takes a 5-field cron (minute hour day-of-month month day-of-week), or 6 fields with seconds first.
- The machine can be off or asleep when a run is due. The run then fires as soon as it's back: the payload's `firedAt` is later than `scheduledFor`, and for `every`, `missedRuns` counts the runs it skipped. Do the work once, not once per missed run.
- When a wake-up arrives, do the work and end your turn. Don't sleep or poll in a loop to wait for time to pass.

## Plugin events

Plugins can wake you too: a Slack message, a new Linear issue, a Grafana alert.

1. `events.topics({ query })` lists the events you can subscribe to, with their `arguments` and `payloadSchema`. If nothing fits, find a plugin with `plugins.search({ query })` (see `codevisor-plugins`).
2. Narrow it with a `filter`: a CEL expression over the payload, e.g. `labels.severity == "critical"`. Check it first with `events.preview({ plugin, event, filter })`, which tests it against recent events.
3. `events.subscribe({ plugin, event, filter, note })`. Pass `account` when the plugin has more than one account, and `once: true` to stop after the first match.
4. The event message shows a short payload. Read the full one with `events.get({ eventId })`.

## Managing subscriptions

- The result of `events.subscribe` has `explained`: read it back to the user in plain words, so they know what will wake you.
- `events.subscriptions()` lists yours, with `pausedReason` if one stopped. A subscription pauses after 200 events in a day.
- `events.unsubscribe({ subscriptionId })` removes one. Remove any you no longer need, such as a routine the user called off.
- An archived chat gets no events.
