import { describe, expect, it, onTestFinished } from "vitest"

import { makeDatabase } from "./index.js"
import { run } from "./test-support.js"

const fixture = async () => {
  const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
  onTestFinished(() => run(db.close))
  const project = await run(db.createProject({ folderPath: "/tmp/session-subscriptions" }))
  const watcher = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  const worker = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
  return { db, watcher, worker }
}

describe("session subscriptions", () => {
  it("finds subscriptions by subscriber and by target until they are removed", async () => {
    const { db, watcher, worker } = await fixture()

    const created = await run(
      db.createSessionSubscription({
        subscriberSessionId: watcher.id.toUpperCase(),
        targetSessionId: worker.id,
        events: ["turn_ended", "turn_ended", "errored"],
        once: true
      })
    )

    expect(created).toMatchObject({
      subscriberSessionId: watcher.id,
      targetSessionId: worker.id,
      events: ["turn_ended", "errored"],
      once: true
    })
    expect(await run(db.listSessionSubscriptions(watcher.id))).toEqual([created])
    expect(await run(db.listSubscriptionsTargeting(worker.id))).toEqual([created])
    expect(await run(db.deleteSessionSubscription(created.id))).toBe(true)
    expect(await run(db.deleteSessionSubscription(created.id))).toBe(false)
    expect(await run(db.listSubscriptionsTargeting(worker.id))).toEqual([])
  })

  it("drops a deleted session's subscriptions in both directions", async () => {
    const { db, watcher, worker } = await fixture()
    await run(
      db.createSessionSubscription({
        subscriberSessionId: watcher.id,
        targetSessionId: worker.id,
        events: ["turn_ended"],
        once: false
      })
    )
    const watched = await run(
      db.createSessionSubscription({
        subscriberSessionId: worker.id,
        targetSessionId: watcher.id,
        events: ["errored"],
        once: false
      })
    )
    expect(await run(db.listSubscriptionsTargeting(watcher.id))).toEqual([watched])

    await run(db.deleteSession(worker.id))

    expect(await run(db.listSessionSubscriptions(watcher.id))).toEqual([])
    expect(await run(db.listSubscriptionsTargeting(watcher.id))).toEqual([])
  })

  it("keeps hidden event prompts marked in the transcript", async () => {
    const { db, watcher } = await fixture()

    await run(
      db.appendEvent("session.output", watcher.id, {
        role: "user",
        messageId: "typed",
        text: "Fix the login bug"
      })
    )
    await run(
      db.appendEvent("session.output", watcher.id, {
        role: "user",
        messageId: "event",
        text: '<codevisor-event type="session.turn_ended">done</codevisor-event>',
        origin: "event"
      })
    )

    const page = await run(db.getTranscriptPage(watcher.id, undefined, 10))
    expect(page.items.map((item) => [item.messageId, item.origin])).toEqual([
      ["typed", undefined],
      ["event", "event"]
    ])
  })
})
