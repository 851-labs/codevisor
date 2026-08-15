import { spawn, type ChildProcess } from "node:child_process"

export interface SessionActivityController {
  readonly update: (sessionId: string, active: boolean) => void
  readonly stop: () => void
}

export interface ActiveWorkSleepInhibitorOptions {
  readonly platform?: NodeJS.Platform
  readonly processId?: number
  readonly spawnCaffeinate?: (processId: number) => ChildProcess
  readonly log?: (message: string) => void
}

/// Prevents idle system sleep only while at least one locally hosted agent
/// turn is active. `-w` also guarantees the assertion disappears if the
/// server crashes instead of reaching `stop()`.
export class ActiveWorkSleepInhibitor implements SessionActivityController {
  private readonly activeSessionIds = new Set<string>()
  private assertionProcess: ChildProcess | undefined

  constructor(
    private readonly processId: number,
    private readonly spawnCaffeinate: (processId: number) => ChildProcess,
    private readonly log: (message: string) => void
  ) {}

  update(sessionId: string, active: boolean): void {
    if (active) {
      this.activeSessionIds.add(sessionId)
    } else {
      this.activeSessionIds.delete(sessionId)
    }
    this.syncAssertion()
  }

  stop(): void {
    this.activeSessionIds.clear()
    this.releaseAssertion()
  }

  private syncAssertion(): void {
    if (this.activeSessionIds.size === 0) {
      this.releaseAssertion()
      return
    }
    if (this.assertionProcess !== undefined) return

    let child: ChildProcess
    try {
      child = this.spawnCaffeinate(this.processId)
    } catch (cause) {
      this.log(
        `Active-work sleep assertion failed: ${cause instanceof Error ? cause.message : String(cause)}`
      )
      return
    }
    this.assertionProcess = child
    child.once("error", (cause) => {
      if (this.assertionProcess !== child) return
      this.assertionProcess = undefined
      this.log(
        `Active-work sleep assertion failed: ${cause instanceof Error ? cause.message : String(cause)}`
      )
    })
    child.once("exit", () => {
      if (this.assertionProcess === child) this.assertionProcess = undefined
    })
  }

  private releaseAssertion(): void {
    const child = this.assertionProcess
    this.assertionProcess = undefined
    try {
      child?.kill()
    } catch (cause) {
      this.log(
        `Active-work sleep assertion cleanup failed: ${cause instanceof Error ? cause.message : String(cause)}`
      )
    }
  }
}

export const makeActiveWorkSleepInhibitor = (
  options: ActiveWorkSleepInhibitorOptions = {}
): SessionActivityController | undefined => {
  const platform = options.platform ?? process.platform
  if (platform !== "darwin") return undefined
  const processId = options.processId ?? process.pid
  const spawnCaffeinate =
    options.spawnCaffeinate ??
    ((ownerProcessId: number) =>
      spawn("/usr/bin/caffeinate", ["-i", "-w", String(ownerProcessId)], {
        stdio: "ignore"
      }))
  return new ActiveWorkSleepInhibitor(
    processId,
    spawnCaffeinate,
    options.log ?? ((message) => console.error(message))
  )
}
