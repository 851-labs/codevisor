import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CodeExecutionResult } from "@codevisor/automation"
import { afterEach, describe, expect, it } from "vitest"

import type { ExecutionTimers } from "./mcp-gateway-execution.js"
import { jobOutputDirectory, makeJobOutputFile } from "./mcp-gateway-job-output.js"
import {
  EXECUTE_JOB_MAX_MS,
  jobCancelledMessage,
  jobExpiredMessage,
  jobLimitMessage,
  makeExecutionJobs,
  MAX_RUNNING_JOBS_PER_SESSION,
  type ExecutionJobFinished,
  type ExecutionRun
} from "./mcp-gateway-jobs.js"

const dataDirs: Array<string> = []

afterEach(() => {
  for (const dir of dataDirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

const manualClock = () => {
  let now = 0
  const scheduled: Array<{ readonly ms: number; readonly fire: () => void; cleared: boolean }> = []
  const timers: ExecutionTimers = {
    now: () => now,
    setTimeout: (callback, ms) => {
      const entry = { ms, fire: callback, cleared: false }
      scheduled.push(entry)
      return () => {
        entry.cleared = true
      }
    }
  }
  const fire = (ms: number): void => {
    const entry = scheduled.find((candidate) => candidate.ms === ms && !candidate.cleared)
    if (entry === undefined) throw new Error(`No pending ${ms}ms timer`)
    entry.cleared = true
    entry.fire()
  }
  return {
    timers,
    fire,
    advance: (ms: number) => {
      now += ms
    }
  }
}

const harness = () => {
  const dataDir = mkdtempSync(join(tmpdir(), "codevisor-jobs-"))
  dataDirs.push(dataDir)
  const clock = manualClock()
  const jobs = makeExecutionJobs({ dataDir, timers: clock.timers })
  const nextFinish = () =>
    new Promise<ExecutionJobFinished>((resolve) => {
      const unsubscribe = jobs.subscribe((event) => {
        unsubscribe()
        resolve(event)
      })
    })
  return { clock, jobs, nextFinish, dataDir }
}

const pendingExecution = (run: ExecutionRun) => {
  const done = Promise.withResolvers<CodeExecutionResult>()
  run.signal.addEventListener(
    "abort",
    () => done.resolve({ result: null, error: "QuickJS execution was cancelled" }),
    { once: true }
  )
  return { promise: done.promise, finish: (result: unknown) => done.resolve({ result }) }
}

const detachedJob = async (h: ReturnType<typeof harness>, sessionId = "session-1") => {
  const run = h.jobs.begin({
    sessionId,
    description: "Wait on a slow agent",
    timeoutMs: 5_000,
    requestSignal: new AbortController().signal
  })
  const execution = pendingExecution(run)
  const outcome = run.outcome(execution.promise)
  run.status("Waiting")
  h.clock.advance(5_000)
  h.clock.fire(5_000)
  const detached = await outcome
  if (detached.kind !== "detached") throw new Error("expected the run to detach")
  return { run, execution, job: detached.job }
}

describe("execution jobs", () => {
  it("lets a waiting poll time out within its budget, then hands over the result once", async () => {
    const h = harness()
    const { execution, job } = await detachedJob(h)

    const polled = h.jobs.wait(job.jobId, 2_000)
    h.clock.fire(2_000)
    expect(await polled).toMatchObject({
      timedOut: true,
      job: { state: "running", progress: "Waiting" }
    })

    const announced = h.nextFinish()
    const waiting = h.jobs.wait(job.jobId, 60_000)
    execution.finish({ ok: true })
    expect(await waiting).toMatchObject({
      timedOut: false,
      job: { state: "completed", result: { ok: true } }
    })
    expect((await announced).collected()).toBe(true)
  })

  it("reports an uncollected finish to subscribers", async () => {
    const h = harness()
    const { run, execution, job } = await detachedJob(h)
    const announced = h.nextFinish()
    run.status("Halfway")
    run.log("[log] checking")
    run.status("  ")

    execution.finish(42)

    const event = await announced
    expect(event.job).toMatchObject({ state: "completed", result: 42, logs: ["[log] checking"] })
    expect(event.job.progress).toBeUndefined()
    expect(event.collected()).toBe(false)
    expect(readFileSync(job.outputPath, "utf8").split("\n")).toEqual([
      "# Codevisor background job " + job.jobId + ": Wait on a slow agent",
      expect.stringMatching(/^# started /),
      "[status] Waiting",
      "[status] Halfway",
      "[log] checking",
      "[completed] 42",
      ""
    ])
  })

  it("cancels a job's in-flight work without announcing it back to the caller", async () => {
    const h = harness()
    const { run, job } = await detachedJob(h)
    const announced = h.nextFinish()

    const cancelled = await h.jobs.cancel(job.jobId)

    expect(run.signal.aborted).toBe(true)
    expect(cancelled).toMatchObject({ state: "cancelled", error: jobCancelledMessage() })
    expect((await announced).collected()).toBe(true)
  })

  it("stops a job at its hard limit and gives tools the longer job deadline", async () => {
    const h = harness()
    const { run, job } = await detachedJob(h)
    expect(run.deadline()).toBe(EXECUTE_JOB_MAX_MS)

    h.clock.fire(EXECUTE_JOB_MAX_MS - 5_000)

    expect(await h.jobs.wait(job.jobId, 0)).toMatchObject({
      job: { state: "failed", error: jobExpiredMessage() }
    })
  })

  it("stops a call instead of detaching once the session has too many jobs running", async () => {
    const h = harness()
    for (let index = 0; index < MAX_RUNNING_JOBS_PER_SESSION; index += 1) await detachedJob(h)
    const run = h.jobs.begin({
      sessionId: "session-1",
      description: "One too many",
      timeoutMs: 5_000,
      requestSignal: new AbortController().signal
    })
    const untrack = run.track("codevisor.sessions.wait")
    const untrackOther = run.track("computer.wait_for")
    const outcome = run.outcome(pendingExecution(run).promise)

    h.clock.fire(5_000)

    const stopped = await outcome
    untrack()
    untrackOther()
    expect(stopped.kind).toBe("finished")
    expect(stopped.kind === "finished" ? stopped.stopped : "").toContain(
      "while codevisor.sessions.wait, computer.wait_for were still running"
    )
    expect(jobLimitMessage(5_000, ["computer.js"])).toContain("while computer.js was still running")
    expect(run.signal.aborted).toBe(true)
  })

  it("cancels only the closed session's jobs and lists jobs without their results", async () => {
    const h = harness()
    const first = await detachedJob(h, "session-1")
    const other = await detachedJob(h, "session-2")
    first.execution.finish({ large: true })
    await h.jobs.wait(first.job.jobId, 0)

    h.jobs.cancelSession("session-2")

    expect(other.run.signal.aborted).toBe(true)
    expect(h.jobs.list("session-1")).toEqual([
      expect.not.objectContaining({ result: expect.anything() })
    ])
    expect(h.jobs.list("session-1")[0]?.state).toBe("completed")
  })

  it("aborts a call whose MCP request is cancelled before it detaches", async () => {
    const h = harness()
    const request = new AbortController()
    const run = h.jobs.begin({
      sessionId: "session-1",
      description: "Cancelled early",
      timeoutMs: 5_000,
      requestSignal: request.signal
    })
    const outcome = run.outcome(pendingExecution(run).promise)

    request.abort()

    expect(await outcome).toMatchObject({ kind: "finished" })
    expect(h.jobs.list("session-1")).toEqual([])
  })
})

describe("execution job bookkeeping", () => {
  it("forgets finished jobs an hour later and answers unknown ids with nothing", async () => {
    const h = harness()
    const { execution, job } = await detachedJob(h)
    execution.finish(1)
    await h.jobs.wait(job.jobId, 0)
    expect(await h.jobs.wait(job.jobId, 0)).toMatchObject({ timedOut: false })
    expect(await h.jobs.cancel(job.jobId)).toMatchObject({ state: "completed", result: 1 })

    h.clock.advance(60 * 60_000 + 1)

    expect(h.jobs.get(job.jobId)).toBeUndefined()
    expect(await h.jobs.wait(job.jobId, 0)).toBeUndefined()
    expect(await h.jobs.cancel(job.jobId)).toBeUndefined()
  })

  it("ends a wait when its caller goes away and keeps only the newest logs", async () => {
    const h = harness()
    const { run, job } = await detachedJob(h)
    for (let line = 0; line <= 2_000; line += 1) run.log(`[log] ${line}`)
    const caller = new AbortController()

    const waiting = h.jobs.wait(job.jobId, 60_000, caller.signal)
    caller.abort()

    const waited = await waiting
    expect(waited?.timedOut).toBe(true)
    expect(waited?.job.logs).toHaveLength(20)
    expect(waited?.job.logs.at(-1)).toBe("[log] 2000")
  })

  it("names the stopped call when nothing was running and writes unserializable results", async () => {
    const h = harness()
    for (let index = 0; index < MAX_RUNNING_JOBS_PER_SESSION; index += 1) await detachedJob(h)
    const run = h.jobs.begin({
      sessionId: "session-1",
      description: "Idle",
      timeoutMs: 5_000,
      requestSignal: new AbortController().signal
    })
    const outcome = run.outcome(pendingExecution(run).promise)
    h.clock.fire(5_000)
    const stopped = await outcome
    expect(stopped.kind === "finished" ? stopped.stopped : "").toContain(
      "while your code was running"
    )

    const other = await detachedJob(h, "session-3")
    const circular: Record<string, unknown> = {}
    circular.self = circular
    const announced = h.nextFinish()
    other.execution.finish(circular)
    await announced
    expect(readFileSync(other.job.outputPath, "utf8")).toContain("[completed] [object Object]")

    const empty = await detachedJob(h, "session-4")
    const emptied = h.nextFinish()
    empty.execution.finish(undefined)
    await emptied
    expect(readFileSync(empty.job.outputPath, "utf8")).toContain("[completed] undefined")
  })
})

describe("job output file", () => {
  it("still settles when its directory can't be created", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "codevisor-job-output-"))
    dataDirs.push(dataDir)
    const blocker = join(dataDir, "not-a-directory")
    writeFileSync(blocker, "")

    await expect(jobOutputDirectory(blocker).ready()).resolves.toBeUndefined()
    const orphan = makeJobOutputFile(Promise.resolve(), join(blocker, "a.log"))
    orphan.append("lost\n")
    await expect(orphan.flushed()).resolves.toBeUndefined()
  })

  it("appends lines in order after the directory is ready", async () => {
    const dataDir = mkdtempSync(join(tmpdir(), "codevisor-job-output-"))
    dataDirs.push(dataDir)
    const directory = jobOutputDirectory(dataDir)
    const file = makeJobOutputFile(directory.ready(), join(directory.path, "a.log"))

    file.append("one\n")
    file.append("two\n")
    await file.flushed()

    expect(readFileSync(join(directory.path, "a.log"), "utf8")).toBe("one\ntwo\n")
  })
})
