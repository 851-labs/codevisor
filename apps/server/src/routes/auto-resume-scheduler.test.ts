import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { appendAndPublish } from "../server-context.js"
import { run } from "../test-support.js"
import {
  advance,
  at,
  createChat,
  exhaustedUntil,
  lastUpdate,
  makeFixture,
  minutes,
  newDatabaseFile,
  openDatabase,
  publishTurn,
  settled,
  start,
  startTurn,
  stopAtLimit,
  unavailable
} from "./auto-resume-scheduler-test-support.js"

describe("auto-resume after a usage limit", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] })
    vi.setSystemTime(start)
  })
  afterEach(() => vi.useRealTimers())

  it("resumes a stopped chat just after the reset its harness reported", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)

    await stopAtLimit(fixture, chat, at(minutes(60)))

    expect(lastUpdate(fixture, chat)).toEqual({
      state: "scheduled",
      resumesAt: at(minutes(60))
    })
    await advance(fixture, minutes(60))
    expect(fixture.resumed).toEqual([])
    await advance(fixture, 30_000)
    expect(fixture.resumed).toEqual([chat])
    expect(lastUpdate(fixture, chat)).toEqual({ state: "resuming" })
    expect(fixture.scheduler.progress(chat)).toBe("resuming")

    await startTurn(fixture, chat)
    expect(lastUpdate(fixture, chat)).toEqual({ state: "cleared" })
    expect(fixture.scheduler.progress(chat)).toBeUndefined()
    await publishTurn(fixture, chat, {})
    expect(await run(fixture.db.getAutoResume(chat))).toBeUndefined()
  })

  it("takes the reset time from the account's exhausted usage window when the stop has none", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    fixture.limits.current = exhaustedUntil(at(minutes(90)))

    await stopAtLimit(fixture, chat, at(-minutes(5)))

    expect(lastUpdate(fixture, chat)).toEqual({
      state: "scheduled",
      resumesAt: at(minutes(90))
    })
    fixture.limits.current = unavailable
    await advance(fixture, minutes(90) + 30_000)
    expect(fixture.resumed).toEqual([chat])
  })

  it("polls with growing backoff when no reset time is known, then resumes once the limit clears", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)

    await stopAtLimit(fixture, chat)
    expect(lastUpdate(fixture, chat)).toEqual({ state: "scheduled" })

    fixture.limits.current = exhaustedUntil(undefined)
    await advance(fixture, minutes(5))
    expect(await run(fixture.db.getAutoResume(chat))).toMatchObject({
      checks: 1,
      checkAt: at(minutes(15))
    })

    fixture.limits.current = new Error("usage endpoint unreachable")
    await advance(fixture, minutes(10) - 1)
    expect(fixture.resumed).toEqual([])
    await advance(fixture, 1)
    expect(fixture.resumed).toEqual([chat])
  })

  it("keeps waiting when the window is still exhausted at the reported reset", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    await stopAtLimit(fixture, chat, at(minutes(30)))

    fixture.limits.current = exhaustedUntil(at(minutes(120)))
    await advance(fixture, minutes(30) + 30_000)

    expect(fixture.resumed).toEqual([])
    expect(lastUpdate(fixture, chat)).toEqual({
      state: "scheduled",
      resumesAt: at(minutes(120))
    })
    fixture.limits.current = unavailable
    await advance(fixture, minutes(90))
    expect(fixture.resumed).toEqual([chat])
  })

  it("starts four chats that hit the limit together at once, and the next as each one starts", async () => {
    const fixture = await makeFixture()
    const chats: Array<string> = []
    for (let index = 0; index < 6; index += 1) chats.push(await createChat(fixture))
    for (const chat of chats) await stopAtLimit(fixture, chat, at(minutes(10)))

    await advance(fixture, minutes(10) + 30_000)
    expect(fixture.resumed).toEqual(chats.slice(0, 4))

    await startTurn(fixture, chats[0]!)
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual(chats.slice(0, 5))

    await advance(fixture, minutes(2))
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual(chats)
  })

  it("hands a chat's slot to the next one when its resume fails, it's archived, or it hits the limit again", async () => {
    const fixture = await makeFixture()
    const chats: Array<string> = []
    for (let index = 0; index < 7; index += 1) chats.push(await createChat(fixture))
    for (const chat of chats) await stopAtLimit(fixture, chat, at(minutes(10)))
    await advance(fixture, minutes(10) + 30_000)
    const [crashed, archived, limited] = chats

    await appendAndPublish(fixture.db, fixture.fanout, "session.error", crashed!, "Claude crashed")
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual(chats.slice(0, 5))
    expect(fixture.scheduler.progress(crashed!)).toBe("failed")

    await appendAndPublish(fixture.db, fixture.fanout, "session.archived", archived!, {})
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual(chats.slice(0, 6))

    await appendAndPublish(fixture.db, fixture.fanout, "session.updated", limited!, {
      turnState: "ended",
      stopReason: "end_turn",
      stopKind: "usageLimit",
      stopDetail: "You've hit your session limit"
    })
    await advance(fixture, 0)
    expect(fixture.resumed).toEqual(chats)
    expect(lastUpdate(fixture, limited!)).toMatchObject({ state: "scheduled" })
  })

  it("cancels the pending resume when the user sends a message, archives the chat, or chooses not to resume", async () => {
    const fixture = await makeFixture()
    const [messaged, archived, declined] = [
      await createChat(fixture),
      await createChat(fixture),
      await createChat(fixture)
    ]
    for (const chat of [messaged, archived, declined]) {
      await stopAtLimit(fixture, chat, at(minutes(10)))
    }

    await publishTurn(fixture, messaged, {})
    await appendAndPublish(fixture.db, fixture.fanout, "session.archived", archived, {})
    await settled(fixture)
    expect(await fixture.scheduler.cancel(declined)).toBe(true)
    expect(await fixture.scheduler.cancel(declined)).toBe(false)

    await advance(fixture, minutes(30))
    expect(fixture.resumed).toEqual([])
    expect(await run(fixture.db.listWaitingAutoResumes)).toEqual([])
    for (const chat of [messaged, archived, declined]) {
      expect(lastUpdate(fixture, chat)).toEqual({ state: "cleared" })
    }
  })

  it("lets the resumed turn run, then backs off further if it hits the limit again", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    await stopAtLimit(fixture, chat)
    await advance(fixture, minutes(5))
    expect(fixture.resumed).toEqual([chat])

    await stopAtLimit(fixture, chat)

    expect(await run(fixture.db.getAutoResume(chat))).toMatchObject({
      state: "waiting",
      checks: 1,
      checkAt: at(minutes(15))
    })
    await advance(fixture, minutes(10))
    expect(fixture.resumed).toEqual([chat, chat])

    await appendAndPublish(fixture.db, fixture.fanout, "session.error", chat, "Codex crashed")
    await settled(fixture)
    expect(await run(fixture.db.getAutoResume(chat))).toBeUndefined()
  })

  it("stops trying after a day of checks that never find the limit reset", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    fixture.limits.current = exhaustedUntil(undefined)
    await stopAtLimit(fixture, chat)

    await advance(fixture, minutes(60 * 30))

    expect(fixture.resumed).toEqual([])
    expect(await run(fixture.db.getAutoResume(chat))).toBeUndefined()
    expect(lastUpdate(fixture, chat)).toEqual({ state: "cleared" })
  })

  it("gives up on a chat whose resume can't be sent, and on one that keeps hitting the limit", async () => {
    const fixture = await makeFixture()
    const [gone, stuck] = [await createChat(fixture), await createChat(fixture)]
    fixture.failResume.add(gone)
    await stopAtLimit(fixture, gone, at(minutes(1)))
    await advance(fixture, minutes(2))
    expect(await run(fixture.db.getAutoResume(gone))).toBeUndefined()
    expect(lastUpdate(fixture, gone)).toEqual({ state: "failed" })
    expect(fixture.scheduler.progress(gone)).toBe("failed")

    await run(
      fixture.db.saveAutoResume({
        sessionId: stuck,
        harnessId: "claude-code",
        state: "resuming",
        checkAt: start.toISOString(),
        checks: 24
      })
    )
    await stopAtLimit(fixture, stuck)
    expect(await run(fixture.db.getAutoResume(stuck))).toBeUndefined()
  })

  it("shows the resume as failed when the resumed turn ends before it starts", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    await stopAtLimit(fixture, chat, at(minutes(1)))
    await advance(fixture, minutes(2))

    await appendAndPublish(fixture.db, fixture.fanout, "session.error", chat, "Claude crashed")
    await settled(fixture)

    expect(lastUpdate(fixture, chat)).toEqual({ state: "failed" })
    expect(await run(fixture.db.getAutoResume(chat))).toBeUndefined()
    await startTurn(fixture, chat)
    expect(lastUpdate(fixture, chat)).toEqual({ state: "cleared" })
  })

  it("waits out a reset further away than one timer can span", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    await stopAtLimit(fixture, chat, at(minutes(60 * 24 * 30)))

    await advance(fixture, minutes(60 * 24 * 25))
    expect(fixture.resumed).toEqual([])
    await advance(fixture, minutes(60 * 24 * 5) + 30_000)
    expect(fixture.resumed).toEqual([chat])
  })

  it("still resumes after the server restarts while a chat is waiting", async () => {
    const filename = newDatabaseFile()
    const before = await makeFixture(await openDatabase(filename))
    const chat = await createChat(before)
    await stopAtLimit(before, chat, at(minutes(45)))
    before.scheduler.close()

    const after = await makeFixture(await openDatabase(filename))
    await after.scheduler.recover()
    await advance(after, minutes(45) + 30_000)

    expect(before.resumed).toEqual([])
    expect(after.resumed).toEqual([chat])
  })
})
