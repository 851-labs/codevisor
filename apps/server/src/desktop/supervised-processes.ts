import { type ChildProcess, spawn } from "node:child_process"

const stopGraceMs = 3000

export interface Ended {
  readonly program: string
  readonly reason: string
}

export class SupervisedProcesses {
  private readonly children: ChildProcess[] = []
  private stopping: Promise<void> | undefined

  constructor(private readonly onEnded: (ended: Ended) => void) {}

  start(program: string, args: ReadonlyArray<string>, env: Record<string, string>): ChildProcess {
    const child = spawn(program, [...args], {
      env: { ...process.env, ...env },
      stdio: ["ignore", "inherit", "inherit"],
      detached: true
    })
    this.children.push(child)
    child.once("error", (error) => this.ended(program, `couldn't start: ${error.message}`))
    child.once("exit", (code) => this.ended(program, `stopped (exit ${code ?? "by a signal"})`))
    return child
  }

  get isStopping(): boolean {
    return this.stopping !== undefined
  }

  stop(): Promise<void> {
    this.stopping ??= this.stopAll()
    return this.stopping
  }

  private ended(program: string, reason: string): void {
    if (this.stopping === undefined) this.onEnded({ program, reason })
  }

  private async stopAll(): Promise<void> {
    for (const child of this.children) signalGroup(child, "SIGTERM")
    const force = setTimeout(() => {
      for (const child of this.children) signalGroup(child, "SIGKILL")
    }, stopGraceMs)
    await Promise.all(this.children.map(exited))
    clearTimeout(force)
    for (const child of this.children) signalGroup(child, "SIGKILL")
  }
}

const signalGroup = (child: ChildProcess, signal: NodeJS.Signals): void => {
  if (child.pid === undefined) return
  try {
    process.kill(-child.pid, signal)
  } catch {
    child.kill(signal)
  }
}

const exited = (child: ChildProcess): Promise<void> =>
  new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null || child.pid === undefined) resolve()
    else child.once("exit", () => resolve())
  })
