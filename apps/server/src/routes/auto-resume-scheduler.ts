import type { HarnessUsageLimits, SessionAutoResumeUpdate } from "@codevisor/api"
import type { AutoResumeRecord, CodevisorDatabaseService } from "@codevisor/db"

import { appendAndPublish, run, swallowError, type EventFanout } from "../server-context.js"
import { autoResumeTrigger, type AutoResumeTrigger } from "./auto-resume-events.js"
import { makeStartSlots } from "./auto-resume-slots.js"
import {
  checkAfterBackoff,
  checkAfterReset,
  futureReset,
  limitState,
  maxUnknownResetChecks
} from "./auto-resume-timing.js"

export interface AutoResumeDependencies {
  readonly db: CodevisorDatabaseService
  readonly fanout: EventFanout
  readonly readLimits: (sessionId: string) => Promise<HarnessUsageLimits | undefined>
  readonly activeAccountId: (harnessId: string) => Promise<string | undefined>
  readonly resume: (sessionId: string) => Promise<void>
}

export type ResumeProgress = "resuming" | "failed"

export interface AutoResumeScheduler {
  readonly recover: () => Promise<void>
  readonly cancel: (sessionId: string) => Promise<boolean>
  readonly progress: (sessionId: string) => ResumeProgress | undefined
  readonly close: () => void
}

export const makeAutoResumeScheduler = (deps: AutoResumeDependencies): AutoResumeScheduler => {
  const { db } = deps
  const timer = makeTimer()
  const serialized = makeSerialQueue()
  const progress = new Map<string, ResumeProgress>()
  const slots = makeStartSlots(() => serialized(arm))

  const publish = async (sessionId: string, update: SessionAutoResumeUpdate): Promise<void> => {
    await appendAndPublish(db, deps.fanout, "session.autoResume.updated", sessionId, update)
  }

  const arm = async (): Promise<void> => {
    const [next] = await run(db.listWaitingAutoResumes)
    if (next === undefined || slots.free() === 0) return timer.clear()

    timer.set(Date.parse(next.checkAt), () => serialized(checkDue))
  }

  const checkDue = async (): Promise<void> => {
    const due = (await run(db.listWaitingAutoResumes)).filter(isDue).slice(0, slots.free())
    await Promise.all(due.map(check))
    await arm()
  }

  const check = async (resume: AutoResumeRecord): Promise<void> => {
    const state = limitState(await readLimits(resume.sessionId), Date.now())
    if (state.kind === "blocked") return waitForReset(resume, state.resetsAt)
    if (state.kind === "blockedWithoutReset") return waitAgain(resume)
    return resumeNow(resume)
  }

  const waitForReset = async (resume: AutoResumeRecord, resetsAt: Date): Promise<void> => {
    const resumesAt = resetsAt.toISOString()
    progress.delete(resume.sessionId)
    await save({ ...resume, resetsAt: resumesAt }, checkAfterReset(resetsAt, Date.now()))
    await publish(resume.sessionId, { state: "scheduled", resumesAt })
  }

  const waitAgain = async (resume: AutoResumeRecord): Promise<void> => {
    const checks = resume.checks + 1
    if (checks > maxUnknownResetChecks) {
      await forget(resume.sessionId)
      return
    }

    await save({ ...withoutReset(resume), checks }, checkAfterBackoff(checks, Date.now()))
    if (progress.delete(resume.sessionId)) await publish(resume.sessionId, { state: "scheduled" })
  }

  const resumeNow = async (resume: AutoResumeRecord): Promise<void> => {
    await run(db.saveAutoResume({ ...resume, state: "resuming" }))
    await markResuming(resume.sessionId)
    slots.hold(resume.sessionId)
    await deps.resume(resume.sessionId).catch(() => failResume(resume.sessionId))
  }

  const markResuming = async (sessionId: string): Promise<void> => {
    if (progress.get(sessionId) === "resuming") return

    progress.set(sessionId, "resuming")
    await publish(sessionId, { state: "resuming" })
  }

  const failResume = async (sessionId: string): Promise<void> => {
    slots.release(sessionId)
    await run(db.deleteAutoResume(sessionId))
    progress.set(sessionId, "failed")
    await publish(sessionId, { state: "failed" })
  }

  const releaseSlot = async (sessionId: string): Promise<void> => {
    if (slots.release(sessionId)) await arm()
  }

  const save = (resume: PendingResume, checkAt: Date) =>
    run(db.saveAutoResume({ ...resume, state: "waiting", checkAt: checkAt.toISOString() }))

  const readLimits = (sessionId: string): Promise<HarnessUsageLimits | undefined> =>
    deps.readLimits(sessionId).catch(() => undefined)

  const forget = async (sessionId: string): Promise<boolean> => {
    const hadProgress = progress.delete(sessionId)
    await releaseSlot(sessionId)
    const deleted = await run(db.deleteAutoResume(sessionId))
    if (!deleted && !hadProgress) return false

    await publish(sessionId, { state: "cleared" })
    return true
  }

  const scheduleAfterStop = async (sessionId: string, reportedReset: string | undefined) => {
    progress.delete(sessionId)
    slots.release(sessionId)
    const checks = await checksAfterStop(sessionId)
    if (checks > maxUnknownResetChecks) {
      await forget(sessionId)
      return
    }

    const { harnessId, harnessAccountId } = await run(db.getSessionSummary(sessionId))
    const resetsAt = futureReset(reportedReset, Date.now()) ?? (await knownReset(sessionId))
    const pending = { sessionId, harnessId, checks, ...optionalAccount(harnessAccountId) }
    await scheduleFirstCheck(pending, resetsAt)
    await arm()
  }

  const checksAfterStop = async (sessionId: string): Promise<number> => {
    const previous = await run(db.getAutoResume(sessionId))
    return previous?.state === "resuming" ? previous.checks + 1 : 0
  }

  const knownReset = async (sessionId: string): Promise<Date | undefined> => {
    const state = limitState(await readLimits(sessionId), Date.now())
    return state.kind === "blocked" ? state.resetsAt : undefined
  }

  const scheduleFirstCheck = async (pending: PendingResume, resetsAt: Date | undefined) => {
    const now = Date.now()
    if (resetsAt === undefined) {
      await save(pending, checkAfterBackoff(pending.checks, now))
      return publish(pending.sessionId, { state: "scheduled" })
    }

    const resumesAt = resetsAt.toISOString()
    await save({ ...pending, resetsAt: resumesAt }, checkAfterReset(resetsAt, now))
    return publish(pending.sessionId, { state: "scheduled", resumesAt })
  }

  const finishResume = async (sessionId: string): Promise<void> => {
    await releaseSlot(sessionId)
    const resume = await run(db.getAutoResume(sessionId))
    if (resume?.state !== "resuming") return

    if (progress.get(sessionId) === "resuming") return failResume(sessionId)
    await run(db.deleteAutoResume(sessionId))
  }

  const handle = async (subjectId: string, trigger: AutoResumeTrigger): Promise<void> => {
    switch (trigger.kind) {
      case "usageLimitStop":
        await scheduleAfterStop(subjectId, trigger.resetsAt)
        break
      case "turnStarted":
        await settleStarted(subjectId)
        break
      case "turnFinished":
        await finishResume(subjectId)
        break
      case "sessionArchived":
        await forget(subjectId)
        break
      case "accountsChanged":
        await followActiveAccount(subjectId)
        break
      case "signedIn":
        await recheckAccount(trigger.accountId)
        break
    }
  }

  const settleStarted = async (sessionId: string): Promise<void> => {
    await releaseSlot(sessionId)
    const resume = await run(db.getAutoResume(sessionId))
    if (resume?.state === "waiting") {
      await forget(sessionId)
      return
    }

    if (progress.delete(sessionId)) await publish(sessionId, { state: "cleared" })
  }

  const followActiveAccount = async (harnessId: string): Promise<void> => {
    const accountId = await deps.activeAccountId(harnessId)
    if (accountId === undefined) return

    const switched = (await run(db.listWaitingAutoResumes)).filter((resume) =>
      stoppedOnOtherAccount(resume, harnessId, accountId)
    )
    for (const resume of switched) {
      await run(db.bindSessionHarnessAccount(resume.sessionId, accountId))
      await checkNow({ ...resume, harnessAccountId: accountId })
    }
    if (switched.length > 0) await arm()
  }

  const recheckAccount = async (accountId: string): Promise<void> => {
    const signedIn = (await run(db.listWaitingAutoResumes)).filter(
      (resume) => resume.harnessAccountId === accountId
    )
    for (const resume of signedIn) await checkNow(resume)
    if (signedIn.length > 0) await arm()
  }

  const checkNow = async (resume: AutoResumeRecord): Promise<void> => {
    await save({ ...withoutReset(resume), checks: 0 }, new Date())
    await markResuming(resume.sessionId)
  }

  const unsubscribe = deps.fanout.subscribe((event) => {
    const trigger = autoResumeTrigger(event)
    if (trigger === undefined) return
    void serialized(() => handle(event.subjectId, trigger)).catch(swallowError)
  })

  return {
    recover: () => serialized(arm),
    cancel: (sessionId) => serialized(() => forget(sessionId)),
    progress: (sessionId) => progress.get(sessionId),
    close: () => {
      unsubscribe()
      timer.close()
      slots.close()
    }
  }
}

const isDue = (resume: AutoResumeRecord): boolean => Date.parse(resume.checkAt) <= Date.now()

const stoppedOnOtherAccount = (
  resume: AutoResumeRecord,
  harnessId: string,
  accountId: string
): boolean =>
  resume.harnessId === harnessId &&
  resume.harnessAccountId !== undefined &&
  resume.harnessAccountId !== accountId

const optionalAccount = (harnessAccountId: string | undefined) =>
  harnessAccountId === undefined ? {} : { harnessAccountId }

type PendingResume = Omit<AutoResumeRecord, "state" | "checkAt">

const withoutReset = ({
  resetsAt: _resetsAt,
  state: _state,
  checkAt: _checkAt,
  ...resume
}: AutoResumeRecord): PendingResume => resume

interface Timer {
  readonly set: (at: number, fire: () => Promise<void>) => void
  readonly clear: () => void
  readonly close: () => void
}

const longestTimerDelayMs = 2 ** 31 - 1

const timerDelay = (at: number): number =>
  Math.min(Math.max(0, at - Date.now()), longestTimerDelayMs)

const makeTimer = (): Timer => {
  let handle: ReturnType<typeof setTimeout> | undefined
  let closed = false

  const clear = (): void => {
    clearTimeout(handle)
    handle = undefined
  }

  return {
    set: (at, fire) => {
      clear()
      /* v8 ignore next */
      if (closed) return
      handle = setTimeout(() => void fire().catch(swallowError), timerDelay(at))
      handle.unref()
    },
    clear,
    close: () => {
      closed = true
      clear()
    }
  }
}

const makeSerialQueue = () => {
  let tail: Promise<unknown> = Promise.resolve()
  return <A>(step: () => Promise<A>): Promise<A> => {
    const next = tail.then(step)
    tail = next.catch(swallowError)
    return next
  }
}
