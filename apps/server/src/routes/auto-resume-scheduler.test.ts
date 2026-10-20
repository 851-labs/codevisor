import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { EventEnvelope, HarnessUsageLimits } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { afterEach, beforeEach, describe, expect, it, onTestFinished, vi } from "vitest"

import { appendAndPublish, makeEventFanout, type EventFanout } from "../server-context.js"
import { run, tempDirs } from "../test-support.js"
import { makeAutoResumeScheduler, type AutoResumeScheduler } from "./auto-resume-scheduler.js"

const start = new Date("2026-10-20T12:00:00.000Z")
const minutes = (count: number): number => count * 60_000
const at = (offsetMs: number): string => new Date(start.getTime() + offsetMs).toISOString()

const unavailable: HarnessUsageLimits = {
  state: "unavailable",
  harnessId: "claude-code",
  windows: [],
  fetchedAt: start.toISOString()
}

const exhaustedUntil = (resetsAt: string | undefined): HarnessUsageLimits => ({
  state: "available",
  harnessId: "claude-code",
  windows: [
    { id: "five-hour", label: "5-hour limit", usedPercent: 100, ...(resetsAt ? { resetsAt } : {}) },
    { id: "seven-day", label: "Weekly limit", usedPercent: 40, resetsAt: at(minutes(9000)) }
  ],
  fetchedAt: start.toISOString()
})

interface Fixture {
  readonly db: CodevisorDatabaseService
  readonly fanout: EventFanout
  readonly scheduler: AutoResumeScheduler
  readonly resumed: Array<string>
  readonly updates: Array<{ readonly sessionId: string; readonly payload: unknown }>
  readonly limits: { current: HarnessUsageLimits | Error }
  readonly failResume: Set<string>
}

const openDatabase = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "server-a" }))
  onTestFinished(() => run(db.close))
  return db
}

const newDatabaseFile = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-auto-resume-"))
  tempDirs.push(dir)
  return join(dir, "codevisor.sqlite")
}

const makeFixture = async (db?: CodevisorDatabaseService): Promise<Fixture> => {
  const database = db ?? (await openDatabase(newDatabaseFile()))
  const fanout = await run(makeEventFanout)
  const resumed: Array<string> = []
  const updates: Array<{ readonly sessionId: string; readonly payload: unknown }> = []
  const limits: { current: HarnessUsageLimits | Error } = { current: unavailable }
  const failResume = new Set<string>()
  fanout.subscribe((event: EventEnvelope) => {
    if (event.kind === "session.autoResume.updated") {
      updates.push({ sessionId: event.subjectId, payload: event.payload })
    }
  })
  const scheduler = makeAutoResumeScheduler({
    db: database,
    fanout,
    readLimits: async () => {
      if (limits.current instanceof Error) throw limits.current
      return limits.current
    },
    resume: async (sessionId) => {
      if (failResume.has(sessionId)) throw new Error("The chat was archived")
      resumed.push(sessionId)
    }
  })
  onTestFinished(() => scheduler.close())
  return { db: database, fanout, scheduler, resumed, updates, limits, failResume }
}

const createChat = async (fixture: Fixture, harnessId = "claude-code"): Promise<string> => {
  const project = await run(fixture.db.createProject({ folderPath: "/tmp/auto-resume" }))
  return (await run(fixture.db.createSession({ projectId: project.id, harnessId }))).id
}

const settled = (fixture: Fixture): Promise<void> => fixture.scheduler.recover()

const publishTurn = async (fixture: Fixture, sessionId: string, ended: Record<string, unknown>) => {
  const turnId = `turn-${Date.now()}`
  await appendAndPublish(fixture.db, fixture.fanout, "session.updated", sessionId, {
    initiatedBy: "user",
    turnId,
    turnState: "started"
  })
  await appendAndPublish(fixture.db, fixture.fanout, "session.updated", sessionId, {
    initiatedBy: "user",
    turnId,
    turnState: "ended",
    stopReason: "end_turn",
    ...ended
  })
  await settled(fixture)
}

const stopAtLimit = (fixture: Fixture, sessionId: string, resetsAt?: string) =>
  publishTurn(fixture, sessionId, {
    stopKind: "usageLimit",
    stopDetail: "You've hit your session limit",
    ...(resetsAt === undefined ? {} : { resetsAt })
  })

const advance = async (fixture: Fixture, ms: number): Promise<void> => {
  await vi.advanceTimersByTimeAsync(ms)
  await settled(fixture)
}

const lastUpdate = (fixture: Fixture, sessionId: string): unknown =>
  fixture.updates.findLast((update) => update.sessionId === sessionId)?.payload

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

    expect(lastUpdate(fixture, chat)).toEqual({ state: "scheduled", resumesAt: at(minutes(60)) })
    await advance(fixture, minutes(60))
    expect(fixture.resumed).toEqual([])
    await advance(fixture, 30_000)
    expect(fixture.resumed).toEqual([chat])
    expect(lastUpdate(fixture, chat)).toEqual({ state: "cleared" })
  })

  it("takes the reset time from the account's exhausted usage window when the stop has none", async () => {
    const fixture = await makeFixture()
    const chat = await createChat(fixture)
    fixture.limits.current = exhaustedUntil(at(minutes(90)))

    await stopAtLimit(fixture, chat, at(-minutes(5)))

    expect(lastUpdate(fixture, chat)).toEqual({ state: "scheduled", resumesAt: at(minutes(90)) })
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
    expect(lastUpdate(fixture, chat)).toEqual({ state: "scheduled", resumesAt: at(minutes(120)) })
    fixture.limits.current = unavailable
    await advance(fixture, minutes(90))
    expect(fixture.resumed).toEqual([chat])
  })

  it("resumes chats that hit the limit together one at a time, in the order they stopped", async () => {
    const fixture = await makeFixture()
    const chats = [await createChat(fixture), await createChat(fixture), await createChat(fixture)]
    for (const chat of chats) await stopAtLimit(fixture, chat, at(minutes(10)))

    await advance(fixture, minutes(10) + 30_000)
    expect(fixture.resumed).toEqual(chats.slice(0, 1))
    await advance(fixture, 15_000)
    expect(fixture.resumed).toEqual(chats.slice(0, 2))
    await advance(fixture, 15_000)
    expect(fixture.resumed).toEqual(chats)
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

  it("resumes right away on the account the user switches to, leaving other harnesses waiting", async () => {
    const fixture = await makeFixture()
    const [claude, codex, unbound] = [
      await createChat(fixture),
      await createChat(fixture, "codex"),
      await createChat(fixture)
    ]
    for (const [id, harnessId] of [
      ["personal", "claude-code"],
      ["work", "claude-code"],
      ["codex-personal", "codex"]
    ] as const) {
      await run(
        fixture.db.saveHarnessAccount({
          id,
          harnessId,
          profileKind: "managed",
          profileKey: id,
          label: id,
          authState: "authenticated",
          canLogin: true,
          canLogout: true
        })
      )
    }
    await run(fixture.db.bindSessionHarnessAccount(claude, "personal"))
    await run(fixture.db.bindSessionHarnessAccount(codex, "codex-personal"))
    for (const chat of [claude, codex, unbound]) await stopAtLimit(fixture, chat, at(minutes(240)))

    await appendAndPublish(fixture.db, fixture.fanout, "harness.auth.updated", "claude-code", {
      activeAccountId: "personal"
    })
    await appendAndPublish(fixture.db, fixture.fanout, "harness.auth.updated", "claude-code", {
      state: "unavailable"
    })
    await settled(fixture)
    expect(fixture.resumed).toEqual([])

    await appendAndPublish(fixture.db, fixture.fanout, "harness.auth.updated", "claude-code", {
      activeAccountId: "work"
    })
    await advance(fixture, 0)

    expect(fixture.resumed).toEqual([claude])
    expect((await run(fixture.db.getSessionSummary(claude))).harnessAccountId).toBe("work")
    expect(await run(fixture.db.getAutoResume(codex))).toMatchObject({ state: "waiting" })
    expect(await run(fixture.db.getAutoResume(unbound))).toMatchObject({ state: "waiting" })
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
