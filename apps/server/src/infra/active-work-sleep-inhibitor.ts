import { spawn, type ChildProcess } from "node:child_process"

export interface SessionActivityController {
  readonly update: (sessionId: string, active: boolean) => void
  readonly stop: () => void
}

export class ActiveWorkSleepInhibitor implements SessionActivityController {
  private readonly activeSessionIds = new Set<string>()
  private assertionProcess: ChildProcess | undefined

  constructor(
    private readonly spawnCaffeinate: () => ChildProcess,
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
      child = this.spawnCaffeinate()
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
  platform: NodeJS.Platform = process.platform
): SessionActivityController | undefined => {
  if (platform !== "darwin") return undefined
  return new ActiveWorkSleepInhibitor(
    () => spawn("/usr/bin/caffeinate", ["-i", "-w", String(process.pid)], { stdio: "ignore" }),
    (message) => console.error(message)
  )
}
