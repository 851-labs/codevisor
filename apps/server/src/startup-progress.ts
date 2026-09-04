import { randomUUID } from "node:crypto"
import { mkdirSync, renameSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { dirname, join, resolve } from "node:path"

// Keep this module limited to Node builtins: main writes a checkpoint before
// importing the server, including native libraries that can stall during load.
export const parseServeArgs = (args: ReadonlyArray<string>): Record<string, string> => {
  const parsed: Record<string, string> = {}
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (arg?.startsWith("--") === true) {
      parsed[arg.slice(2)] = args[index + 1] ?? ""
      index += 1
    }
  }
  return parsed
}

const milestones = {
  loadingRuntime: 2,
  acquiringDatabase: 3,
  openingDatabase: 3,
  restoringTerminals: 4,
  initializingServices: 5,
  checkingHealth: 6,
  ready: 6
} as const

export interface StartupWork {
  readonly id: string
  readonly completed: number
  readonly total: number
  readonly name: string
}

export interface ServerStartupProgress {
  readonly version: 1
  readonly bootId: string
  readonly pid: number
  readonly startedAt: string
  readonly updatedAt: string
  readonly elapsedMs: number
  readonly stage: keyof typeof milestones
  readonly completed: number
  readonly total: 7
  readonly state: "starting" | "ready" | "failed"
  readonly work?: StartupWork
  readonly error?: string
}

export const makeStartupReporter = (
  args: Record<string, string>,
  log: (line: string) => void = console.error
) => {
  const bootId = (args["boot-id"] ??= randomUUID())
  const database = resolve(
    args.db ??
      join(
        process.env.CODEVISOR_DATA_DIR ?? join(homedir(), ".codevisor", "data"),
        "codevisor-server.sqlite"
      )
  )
  const path = resolve(args["startup-status"] ?? join(dirname(database), "server-startup.json"))
  const startedAt = new Date(Date.now() - process.uptime() * 1_000).toISOString()
  let stage: keyof typeof milestones = "loadingRuntime"
  let lastLog: string | undefined
  const report = (state: ServerStartupProgress["state"], work?: StartupWork, error?: string) => {
    const progress: ServerStartupProgress = {
      version: 1,
      bootId,
      pid: process.pid,
      startedAt,
      updatedAt: new Date().toISOString(),
      elapsedMs: Math.round(process.uptime() * 1_000),
      stage,
      completed: milestones[stage],
      total: 7,
      state,
      ...(work === undefined ? {} : { work }),
      ...(error === undefined ? {} : { error })
    }
    const key = `${stage}:${state}`
    if (key !== lastLog) {
      log(
        `[startup ${bootId}] ${stage} ${state} (${progress.elapsedMs} ms)${error === undefined ? "" : `: ${error}`}`
      )
      lastLog = key
    }
    try {
      mkdirSync(dirname(path), { recursive: true })
      const temporary = `${path}.${process.pid}.tmp`
      writeFileSync(temporary, `${JSON.stringify(progress)}\n`, { mode: 0o600 })
      renameSync(temporary, path)
    } catch (cause) {
      // Diagnostics must not turn a healthy server into a failed launch.
      log(`Startup status unavailable: ${String(cause)}`)
    }
  }
  return {
    checkpoint(next: keyof typeof milestones) {
      stage = next
      report(next === "ready" ? "ready" : "starting")
    },
    work(work: StartupWork) {
      report("starting", work)
    },
    fail(cause: unknown) {
      report("failed", undefined, cause instanceof Error ? cause.message : String(cause))
    }
  }
}

export type StartupReporter = ReturnType<typeof makeStartupReporter>
