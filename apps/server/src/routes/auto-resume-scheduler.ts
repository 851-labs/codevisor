import type { HarnessUsageLimits, SessionAutoResumeUpdate } from "@codevisor/api"
import type { AutoResumeRecord, CodevisorDatabaseService } from "@codevisor/db"

import { appendAndPublish, run, swallowError, type EventFanout } from "../server-context.js"
import { autoResumeTrigger, type AutoResumeTrigger } from "./auto-resume-events.js"
import {
  checkAfterBackoff,
  checkAfterReset,
  futureReset,
  limitState,
  maxUnknownResetChecks,
  nextFireAt
} from "./auto-resume-timing.js"

export interface AutoResumeDependencies {
  readonly db: CodevisorDatabaseService
  readonly fanout: EventFanout
  readonly readLimits: (sessionId: string) => Promise<HarnessUsageLimits | undefined>
  readonly activeAccountId: (harnessId: string) => Promise<string | undefined>
  readonly resume: (sessionId: string) => Promise<void>
}

export interface AutoResumeScheduler {
  readonly recover: () => Promise<void>
  readonly cancel: (sessionId: string) => Promise<boolean>
  readonly close: () => void
}

export const makeAutoResumeScheduler = (deps: AutoResumeDependencies): AutoResumeScheduler => {
  const { db } = deps
  const timer = makeTimer()
  const serialized = makeSerialQueue()
  let lastResumeAt: number | undefined

  const publish = async (sessionId: string, update: SessionAutoResumeUpdate): Promise<void> => {
    await appendAndPublish(db, deps.fanout, "session.autoResume.updated", sessionId, update)
  }

  const arm = async (): Promise<void> => {
    const [next] = await run(db.listWaitingAutoResumes)
    if (next === undefined) return timer.clear()

    timer.set(nextFireAt(next.checkAt, lastResumeAt), () => serialized(checkDue))
  }

  const checkDue = async (): Promise<void> => {
    const [due] = await run(db.listWaitingAutoResumes)
    if (due !== undefined && isDue(due, lastResumeAt)) await check(due)
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
  }

  const resumeNow = async (resume: AutoResumeRecord): Promise<void> => {
    await run(db.saveAutoResume({ ...resume, state: "resuming" }))
    await publish(resume.sessionId, { state: "cleared" })
    lastResumeAt = Date.now()
    await deps.resume(resume.sessionId).catch(() => forget(resume.sessionId))
  }

  const save = (resume: PendingResume, checkAt: Date) =>
    run(db.saveAutoResume({ ...resume, state: "waiting", checkAt: checkAt.toISOString() }))

  const readLimits = (sessionId: string): Promise<HarnessUsageLimits | undefined> =>
    deps.readLimits(sessionId).catch(() => undefined)

  const forget = async (sessionId: string): Promise<boolean> => {
    if (!(await run(db.deleteAutoResume(sessionId)))) return false
    await publish(sessionId, { state: "cleared" })
    return true
  }

  const scheduleAfterStop = async (sessionId: string, reportedReset: string | undefined) => {
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
    const resume = await run(db.getAutoResume(sessionId))
    if (resume?.state === "resuming") await run(db.deleteAutoResume(sessionId))
  }

  const handle = async (subjectId: string, trigger: AutoResumeTrigger): Promise<void> => {
    switch (trigger.kind) {
      case "usageLimitStop":
        await scheduleAfterStop(subjectId, trigger.resetsAt)
        break
      case "turnStarted":
        await settleWaiting(subjectId)
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

  const settleWaiting = async (sessionId: string): Promise<void> => {
    const resume = await run(db.getAutoResume(sessionId))
    if (resume?.state === "waiting") await forget(sessionId)
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

  const checkNow = (resume: AutoResumeRecord) =>
    save({ ...withoutReset(resume), checks: 0 }, new Date())

  const unsubscribe = deps.fanout.subscribe((event) => {
    const trigger = autoResumeTrigger(event)
    if (trigger === undefined) return
    void serialized(() => handle(event.subjectId, trigger)).catch(swallowError)
  })

  return {
    recover: () => serialized(arm),
    cancel: (sessionId) => serialized(() => forget(sessionId)),
    close: () => {
      unsubscribe()
      timer.close()
    }
  }
}

const isDue = (resume: AutoResumeRecord, lastResumeAt: number | undefined): boolean =>
  nextFireAt(resume.checkAt, lastResumeAt) <= Date.now()

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
