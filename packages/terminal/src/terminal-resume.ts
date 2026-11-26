import type { ProcessIdentity } from "@codevisor/processes"

import type { RunningTerminal } from "./frames.js"
import { makeOscScanner, type OscEvent, type OscScanner } from "./osc-scanner.js"
import {
  MAX_RESUME_BODY,
  readResumeReport,
  RESUME_PREFIX,
  type ResumeReport
} from "./program-resume-report.js"
import type { SavedResume } from "./types.js"

export const OWNER_EXIT_GRACE_MS = 2000
export const MAX_RESUME_RECORDS = 16

export interface TerminalResume {
  readonly observe: (terminal: RunningTerminal, data: string) => void
  readonly end: (terminal: RunningTerminal) => void
  readonly saved: (terminal: RunningTerminal) => SavedResume | undefined
  readonly subscribe: (listener: () => void) => () => void
}

export const makeTerminalResume = (userId: number | undefined): TerminalResume => {
  const states = new WeakMap<RunningTerminal, ResumeState>()
  const listeners = new Set<() => void>()
  const changed = (): void => {
    for (const listener of listeners) listener()
  }

  return {
    observe: (terminal, data) => {
      const token = terminal.resumeToken
      if (token === undefined || terminal.closed) return

      const state = stateFor(states, terminal)
      for (const report of reportsIn(state.scanner.scan(data), token)) {
        state.queue = state.queue
          .then(() => applyReport(terminal, state, report))
          .then((didChange) => {
            if (didChange) changed()
          })
          .catch(() => undefined)
      }
    },
    end: (terminal) => {
      states.delete(terminal)
    },
    saved: (terminal) => {
      const record = liveRecord(terminal, states.get(terminal))
      if (record === undefined || userId === undefined) return undefined
      const { argv, cwd, cwdFromReport } = record
      return { argv, cwd, cwdFromReport, uid: userId }
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}

type ActionableReport = Exclude<ResumeReport, { type: "ignored" }>

interface ResumeRecord {
  readonly owner: ProcessIdentity
  readonly argv: ReadonlyArray<string>
  readonly cwd: string | undefined
  readonly cwdFromReport: boolean
}

interface ResumeState {
  readonly scanner: OscScanner
  readonly records: Map<number, ResumeRecord>
  readonly acceptedTimes: Map<number, number>
  queue: Promise<void>
}

const stateFor = (
  states: WeakMap<RunningTerminal, ResumeState>,
  terminal: RunningTerminal
): ResumeState => {
  const existing = states.get(terminal)
  if (existing !== undefined) return existing

  const state: ResumeState = {
    scanner: makeOscScanner([
      { prefix: RESUME_PREFIX, maxLength: RESUME_PREFIX.length + MAX_RESUME_BODY }
    ]),
    records: new Map(),
    acceptedTimes: new Map(),
    queue: Promise.resolve()
  }
  states.set(terminal, state)
  return state
}

const reportsIn = (
  events: ReadonlyArray<OscEvent>,
  token: string
): ReadonlyArray<ActionableReport> => {
  const nowSeconds = Math.floor(Date.now() / 1000)
  return events.flatMap((event) => {
    if (event.type !== "osc") return []
    const report = readResumeReport(event.body.slice(RESUME_PREFIX.length), token, nowSeconds)
    return report.type === "ignored" ? [] : [report]
  })
}

const applyReport = async (
  terminal: RunningTerminal,
  state: ResumeState,
  report: ActionableReport
): Promise<boolean> => {
  if (report.pid !== undefined && outOfOrder(state, report.pid, report.time)) return false
  if (report.type === "rejected") return forget(state, report.pid)

  const tree = terminal.process.tree
  const owner = await tree?.member(report.pid)
  if (tree === undefined || owner === undefined) return forget(state, report.pid)

  rememberTime(state, report.pid, report.time)
  if (report.type === "clear") return forget(state, report.pid)

  const cwd = report.cwd ?? (await tree.cwd(report.pid))
  remember(state, report.pid, {
    owner,
    argv: report.argv,
    cwd,
    cwdFromReport: report.cwd !== undefined
  })
  return true
}

const outOfOrder = (state: ResumeState, pid: number, time: number): boolean =>
  time < (state.acceptedTimes.get(pid) ?? 0)

const forget = (state: ResumeState, pid: number | undefined): boolean =>
  pid !== undefined && state.records.delete(pid)

const rememberTime = (state: ResumeState, pid: number, time: number): void => {
  state.acceptedTimes.delete(pid)
  state.acceptedTimes.set(pid, time)
  trimOldest(state.acceptedTimes)
}

const remember = (state: ResumeState, pid: number, record: ResumeRecord): void => {
  state.records.delete(pid)
  state.records.set(pid, record)
  trimOldest(state.records)
}

const trimOldest = (entries: Map<number, unknown>): void => {
  while (entries.size > MAX_RESUME_RECORDS) entries.delete(entries.keys().next().value!)
}

const liveRecord = (
  terminal: RunningTerminal,
  state: ResumeState | undefined
): ResumeRecord | undefined => {
  const tree = terminal.process.tree
  if (state === undefined || tree === undefined || terminal.closed) return undefined
  return [...state.records.values()]
    .toReversed()
    .find((record) => tree.recentlyAlive(record.owner, OWNER_EXIT_GRACE_MS))
}
