import { randomBytes } from "node:crypto"
import { join } from "node:path"

import type { ExecutionJob, ExecutionJobState } from "@codevisor/api"
import type { CodeExecutionResult } from "@codevisor/automation"

import type { ExecutionTimers } from "./mcp-gateway-execution.js"
import {
  jobOutputDirectory,
  makeJobOutputFile,
  type JobOutputFile
} from "./mcp-gateway-job-output.js"

export const EXECUTE_JOB_MAX_MS = 30 * 60_000
export const MAX_RUNNING_JOBS_PER_SESSION = 8

export interface ExecutionJobFinished {
  readonly job: ExecutionJob
  readonly collected: () => boolean
}

export type RunOutcome =
  | { readonly kind: "finished"; readonly result: CodeExecutionResult; readonly stopped?: string }
  | { readonly kind: "detached"; readonly job: ExecutionJob }

export interface ExecutionRun {
  readonly signal: AbortSignal
  readonly deadline: () => number
  readonly status: (text: string) => void
  readonly log: (line: string) => void
  readonly track: (path: string) => () => void
  readonly outcome: (execution: Promise<CodeExecutionResult>) => Promise<RunOutcome>
}

export interface BeginRunOptions {
  readonly sessionId: string
  readonly description: string
  readonly timeoutMs: number
  readonly requestSignal: AbortSignal
}

export interface JobWait {
  readonly job: ExecutionJob
  readonly timedOut: boolean
}

export interface ExecutionJobs {
  readonly begin: (options: BeginRunOptions) => ExecutionRun
  readonly get: (jobId: string) => ExecutionJob | undefined
  readonly list: (sessionId: string) => ReadonlyArray<ExecutionJob>
  readonly wait: (
    jobId: string,
    timeoutMs: number,
    signal?: AbortSignal
  ) => Promise<JobWait | undefined>
  readonly cancel: (jobId: string) => Promise<ExecutionJob | undefined>
  readonly cancelSession: (sessionId: string) => void
  readonly subscribe: (listener: (finished: ExecutionJobFinished) => void) => () => void
}

export const jobLimitMessage = (timeoutMs: number, running: ReadonlyArray<string>): string =>
  `execute reached timeout_ms ${timeoutMs} ${stillRunningClause(running)}, and this session ` +
  `already has ${MAX_RUNNING_JOBS_PER_SESSION} background jobs running, so it was stopped and its ` +
  "pending tool calls were cancelled. Check or cancel the running jobs with " +
  "tools.codevisor.jobs.list() and tools.codevisor.jobs.cancel({ jobId })."

export const jobExpiredMessage = (): string =>
  `Background job ran for its ${EXECUTE_JOB_MAX_MS / 60_000}-minute limit; its pending tool calls were cancelled.`

export const jobCancelledMessage = (): string => "Cancelled with jobs.cancel."

export const makeExecutionJobs = (options: {
  readonly dataDir: string
  readonly timers: ExecutionTimers
}): ExecutionJobs => {
  const { timers } = options
  const directory = jobOutputDirectory(options.dataDir)
  const registry = new Map<string, Job>()
  const listeners = new Set<(finished: ExecutionJobFinished) => void>()

  const prune = (): void => {
    for (const [jobId, job] of registry) {
      if (expiredRecord(job, timers.now())) registry.delete(jobId)
    }
  }

  const runningCount = (sessionId: string): number =>
    [...registry.values()].filter((job) => job.sessionId === sessionId && job.state === "running")
      .length

  const announce = (job: Job): void => {
    const finished = { job: snapshot(job, timers.now()), collected: () => job.collected }
    for (const listener of listeners) listener(finished)
  }

  const settle = (job: Job, result: CodeExecutionResult): void => {
    job.unlinkRequest()
    job.cancelHardCap?.()
    applyResult(job, result, timers.now())
    job.settled.resolve()
    if (job.output === undefined) return
    job.output.append(finalBlock(job))
    void job.output.flushed().then(() => announce(job))
  }

  const detach = (job: Job): ExecutionJob => {
    job.detached = true
    job.unlinkRequest()
    job.output = makeJobOutputFile(directory.ready(), join(directory.path, `${job.jobId}.log`))
    job.output.append(historyBlock(job))
    job.cancelHardCap = timers.setTimeout(
      () => stop(job, "expired"),
      EXECUTE_JOB_MAX_MS - (timers.now() - job.startedAtMs)
    )
    registry.set(job.jobId, job)
    return snapshot(job, timers.now())
  }

  const outcome = async (
    job: Job,
    timeoutMs: number,
    execution: Promise<CodeExecutionResult>
  ): Promise<RunOutcome> => {
    const settled = execution.then((result) => settle(job, result))
    const yielded = Promise.withResolvers<void>()
    const cancelYield = timers.setTimeout(yielded.resolve, timeoutMs)
    const first = await Promise.race([settled.then(() => "finished"), yielded.promise])
    cancelYield()
    if (first === "finished") return { kind: "finished", result: await execution }
    if (runningCount(job.sessionId) >= MAX_RUNNING_JOBS_PER_SESSION) {
      const stopped = jobLimitMessage(timeoutMs, job.running)
      job.controller.abort(new Error(stopped))
      return { kind: "finished", result: await execution, stopped }
    }
    return { kind: "detached", job: detach(job) }
  }

  const begin = (run: BeginRunOptions): ExecutionRun => {
    prune()
    const job = newJob(run, uniqueJobId(registry), directory.path, timers.now())
    return {
      signal: job.controller.signal,
      deadline: () => jobDeadline(job, run.timeoutMs),
      status: (text) => noteStatus(job, text),
      log: (line) => noteLog(job, line),
      track: (path) => trackTool(job, path),
      outcome: (execution) => outcome(job, run.timeoutMs, execution)
    }
  }

  const collectedSnapshot = (job: Job): ExecutionJob => {
    if (job.state !== "running") job.collected = true
    return snapshot(job, timers.now())
  }

  const settledWithin = async (job: Job, timeoutMs: number, signal?: AbortSignal) => {
    const gaveUp = Promise.withResolvers<void>()
    const cancelTimer = timers.setTimeout(gaveUp.resolve, timeoutMs)
    signal?.addEventListener("abort", () => gaveUp.resolve(), { once: true })
    await Promise.race([job.settled.promise, gaveUp.promise])
    cancelTimer()
  }

  return {
    begin,
    get: (jobId) => {
      prune()
      const job = registry.get(jobId)
      return job === undefined ? undefined : collectedSnapshot(job)
    },
    list: (sessionId) => {
      prune()
      return [...registry.values()]
        .filter((job) => job.sessionId === sessionId)
        .map((job) => withoutResult(snapshot(job, timers.now())))
    },
    wait: async (jobId, timeoutMs, signal) => {
      const job = registry.get(jobId)
      if (job === undefined) return undefined
      if (job.state === "running") await settledWithin(job, timeoutMs, signal)
      return { job: collectedSnapshot(job), timedOut: job.state === "running" }
    },
    cancel: async (jobId) => {
      const job = registry.get(jobId)
      if (job === undefined) return undefined
      job.collected = true
      if (job.state === "running") stop(job, "cancelled")
      await job.settled.promise
      return snapshot(job, timers.now())
    },
    cancelSession: (sessionId) => {
      for (const job of registry.values()) {
        if (job.sessionId !== sessionId || job.state !== "running") continue
        job.collected = true
        stop(job, "cancelled")
      }
    },
    subscribe: (listener) => {
      listeners.add(listener)
      return () => listeners.delete(listener)
    }
  }
}

const LOG_TAIL = 20
const MAX_KEPT_LOGS = 2_000
const FINISHED_RETENTION_MS = 60 * 60_000
const JOB_ID_BYTES = 5

type StopReason = "cancelled" | "expired"

interface Job {
  readonly jobId: string
  readonly sessionId: string
  readonly description: string
  readonly startedAt: string
  readonly startedAtMs: number
  readonly outputPath: string
  readonly controller: AbortController
  readonly settled: PromiseWithResolvers<void>
  readonly running: Array<string>
  readonly logs: Array<string>
  readonly unlinkRequest: () => void
  state: ExecutionJobState
  detached: boolean
  collected: boolean
  progress?: string
  stopReason?: StopReason
  finishedAt?: string
  finishedAtMs?: number
  result?: unknown
  error?: string
  output?: JobOutputFile
  cancelHardCap?: () => void
}

const newJob = (run: BeginRunOptions, jobId: string, directory: string, nowMs: number): Job => {
  const controller = new AbortController()
  const abortWithRequest = (): void => controller.abort(run.requestSignal.reason)
  run.requestSignal.addEventListener("abort", abortWithRequest, { once: true })
  return {
    jobId,
    sessionId: run.sessionId,
    description: run.description,
    startedAt: new Date().toISOString(),
    startedAtMs: nowMs,
    outputPath: join(directory, `${jobId}.log`),
    controller,
    settled: Promise.withResolvers<void>(),
    running: [],
    logs: [],
    unlinkRequest: () => run.requestSignal.removeEventListener("abort", abortWithRequest),
    state: "running",
    detached: false,
    collected: false
  }
}

const uniqueJobId = (registry: ReadonlyMap<string, Job>): string => {
  const jobId = randomBytes(JOB_ID_BYTES).toString("hex")
  /* v8 ignore next */
  if (registry.has(jobId)) return uniqueJobId(registry)
  return jobId
}

const jobDeadline = (job: Job, timeoutMs: number): number => {
  if (job.detached) return job.startedAtMs + EXECUTE_JOB_MAX_MS
  return job.startedAtMs + timeoutMs
}

const stop = (job: Job, reason: StopReason): void => {
  job.stopReason = reason
  job.controller.abort(new Error(stopMessage(reason)))
}

const stopMessage = (reason: StopReason): string => {
  if (reason === "cancelled") return jobCancelledMessage()
  return jobExpiredMessage()
}

const noteStatus = (job: Job, text: string): void => {
  const trimmed = text.trim()
  if (trimmed.length === 0) {
    delete job.progress
    return
  }
  job.progress = trimmed
  job.output?.append(`[status] ${trimmed}\n`)
}

const noteLog = (job: Job, line: string): void => {
  job.logs.push(line)
  if (job.logs.length > MAX_KEPT_LOGS) job.logs.shift()
  job.output?.append(`${line}\n`)
}

const trackTool = (job: Job, path: string): (() => void) => {
  job.running.push(path)
  job.output?.append(`[tool] ${path} started\n`)
  return () => {
    job.running.splice(job.running.indexOf(path), 1)
    job.output?.append(`[tool] ${path} finished\n`)
  }
}

const applyResult = (job: Job, result: CodeExecutionResult, nowMs: number): void => {
  job.finishedAtMs = nowMs
  job.finishedAt = new Date().toISOString()
  const error = finalError(job, result)
  job.state = finalState(job, error)
  if (error === undefined) job.result = result.result
  else job.error = error
}

const finalError = (job: Job, result: CodeExecutionResult): string | undefined => {
  if (job.stopReason !== undefined) return stopMessage(job.stopReason)
  return result.error
}

const finalState = (job: Job, error: string | undefined): ExecutionJobState => {
  if (job.stopReason === "cancelled") return "cancelled"
  if (error !== undefined) return "failed"
  return "completed"
}

const expiredRecord = (job: Job, nowMs: number): boolean =>
  job.finishedAtMs !== undefined && nowMs - job.finishedAtMs > FINISHED_RETENTION_MS

const stillRunningClause = (running: ReadonlyArray<string>): string => {
  if (running.length === 0) return "while your code was running"
  return `while ${[...new Set(running)].join(", ")} ${running.length === 1 ? "was" : "were"} still running`
}

const snapshot = (job: Job, nowMs: number): ExecutionJob => ({
  jobId: job.jobId,
  sessionId: job.sessionId,
  description: job.description,
  state: job.state,
  startedAt: job.startedAt,
  ...(job.finishedAt === undefined ? {} : { finishedAt: job.finishedAt }),
  elapsedMs: Math.round((job.finishedAtMs ?? nowMs) - job.startedAtMs),
  running: [...new Set(job.running)],
  ...(job.progress === undefined ? {} : { progress: job.progress }),
  logs: job.logs.slice(-LOG_TAIL),
  outputPath: job.outputPath,
  ...(job.result === undefined ? {} : { result: job.result }),
  ...(job.error === undefined ? {} : { error: job.error })
})

const withoutResult = ({ result: _result, ...job }: ExecutionJob): ExecutionJob => job

const historyBlock = (job: Job): string =>
  [
    `# Codevisor background job ${job.jobId}: ${job.description}`,
    `# started ${job.startedAt}`,
    ...(job.progress === undefined ? [] : [`[status] ${job.progress}`]),
    ...job.logs,
    ""
  ].join("\n")

const finalBlock = (job: Job): string => {
  if (job.error !== undefined) return `[${job.state}] ${job.error}\n`
  return `[completed] ${safeJson(job.result)}\n`
}

const safeJson = (value: unknown): string => {
  try {
    return JSON.stringify(value) ?? "undefined"
  } catch {
    return String(value)
  }
}
