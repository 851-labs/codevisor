import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { EventEnvelope, HarnessUsageLimits } from "@codevisor/api"
import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import { onTestFinished, vi } from "vitest"

import { appendAndPublish, makeEventFanout, type EventFanout } from "../server-context.js"
import { run, tempDirs } from "../test-support.js"
import { makeAutoResumeScheduler, type AutoResumeScheduler } from "./auto-resume-scheduler.js"

export const start = new Date("2026-10-20T12:00:00.000Z")
export const minutes = (count: number): number => count * 60_000
export const at = (offsetMs: number): string => new Date(start.getTime() + offsetMs).toISOString()

export const unavailable: HarnessUsageLimits = {
  state: "unavailable",
  harnessId: "claude-code",
  windows: [],
  fetchedAt: start.toISOString()
}

export const exhaustedUntil = (resetsAt: string | undefined): HarnessUsageLimits => ({
  state: "available",
  harnessId: "claude-code",
  windows: [
    {
      id: "five-hour",
      label: "5-hour limit",
      usedPercent: 100,
      ...(resetsAt ? { resetsAt } : {})
    },
    {
      id: "seven-day",
      label: "Weekly limit",
      usedPercent: 40,
      resetsAt: at(minutes(9000))
    }
  ],
  fetchedAt: start.toISOString()
})

export interface Fixture {
  readonly db: CodevisorDatabaseService
  readonly fanout: EventFanout
  readonly scheduler: AutoResumeScheduler
  readonly resumed: Array<string>
  readonly updates: Array<{
    readonly sessionId: string
    readonly payload: unknown
  }>
  readonly limits: { current: HarnessUsageLimits | Error }
  readonly failResume: Set<string>
}

export const openDatabase = async (filename: string) => {
  const db = await run(makeDatabase({ filename, serverId: "server-a" }))
  onTestFinished(() => run(db.close))
  return db
}

export const newDatabaseFile = (): string => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-auto-resume-"))
  tempDirs.push(dir)
  return join(dir, "codevisor.sqlite")
}

export const makeFixture = async (db?: CodevisorDatabaseService): Promise<Fixture> => {
  const database = db ?? (await openDatabase(newDatabaseFile()))
  const fanout = await run(makeEventFanout)
  const resumed: Array<string> = []
  const updates: Array<{
    readonly sessionId: string
    readonly payload: unknown
  }> = []
  const limits: { current: HarnessUsageLimits | Error } = {
    current: unavailable
  }
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
    activeAccountId: async (harnessId) =>
      (await run(database.listHarnessAccounts(harnessId))).find((account) => account.isActive)?.id,
    resume: async (sessionId) => {
      if (failResume.has(sessionId)) throw new Error("The chat was archived")
      resumed.push(sessionId)
    }
  })
  onTestFinished(() => scheduler.close())
  return {
    db: database,
    fanout,
    scheduler,
    resumed,
    updates,
    limits,
    failResume
  }
}

export const createChat = async (fixture: Fixture, harnessId = "claude-code"): Promise<string> => {
  const project = await run(fixture.db.createProject({ folderPath: "/tmp/auto-resume" }))
  return (await run(fixture.db.createSession({ projectId: project.id, harnessId }))).id
}

export const settled = (fixture: Fixture): Promise<void> => fixture.scheduler.recover()

export const publishTurn = async (
  fixture: Fixture,
  sessionId: string,
  ended: Record<string, unknown>
) => {
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

export const startTurn = async (fixture: Fixture, sessionId: string) => {
  await appendAndPublish(fixture.db, fixture.fanout, "session.updated", sessionId, {
    initiatedBy: "user",
    turnId: `turn-${Date.now()}`,
    turnState: "started"
  })
  await settled(fixture)
}

export const stopAtLimit = (fixture: Fixture, sessionId: string, resetsAt?: string) =>
  publishTurn(fixture, sessionId, {
    stopKind: "usageLimit",
    stopDetail: "You've hit your session limit",
    ...(resetsAt === undefined ? {} : { resetsAt })
  })

export const advance = async (fixture: Fixture, ms: number): Promise<void> => {
  await vi.advanceTimersByTimeAsync(ms)
  await settled(fixture)
}

export const accountsChanged = async (fixture: Fixture, harnessId: string) => {
  await appendAndPublish(fixture.db, fixture.fanout, "harness.auth.updated", harnessId, {})
  await settled(fixture)
}

export const signInFlow = async (fixture: Fixture, flow: Record<string, unknown>) => {
  await appendAndPublish(
    fixture.db,
    fixture.fanout,
    "harness.authFlow.updated",
    "claude-code",
    flow
  )
  await settled(fixture)
}

export const saveAccounts = async (fixture: Fixture, ids: ReadonlyArray<string>) => {
  for (const id of ids) {
    await run(
      fixture.db.saveHarnessAccount({
        id,
        harnessId: "claude-code",
        profileKind: "managed",
        profileKey: id,
        label: id,
        authState: "authenticated",
        canLogin: true,
        canLogout: true
      })
    )
  }
}

export const lastUpdate = (fixture: Fixture, sessionId: string): unknown =>
  fixture.updates.findLast((update) => update.sessionId === sessionId)?.payload
