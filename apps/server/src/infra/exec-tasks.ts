import { spawn, type ChildProcessByStdio } from "node:child_process"
import { randomUUID } from "node:crypto"
import { createWriteStream, mkdirSync, type WriteStream } from "node:fs"
import { readFile } from "node:fs/promises"
import { join } from "node:path"
import type { Readable } from "node:stream"

import type { ExecTask } from "@codevisor/api"

import { OutputTail } from "./exec-output-tail.js"

export interface ExecCommand {
  readonly command: string
  readonly description: string
  readonly cwd: string
  readonly timeoutMs: number
  readonly owner?: string
}

export interface ExecResult {
  readonly exitCode: number | null
  readonly output: string
  readonly timedOut: boolean
  readonly durationMs: number
  readonly outputPath: string
}

export interface FinishedExecTask {
  readonly task: ExecTask
  readonly outputTail: string
}

export interface ExecTasks {
  readonly run: (command: ExecCommand) => Promise<ExecResult>
  readonly start: (
    command: Omit<ExecCommand, "timeoutMs">,
    onFinish: (finished: FinishedExecTask) => void
  ) => ExecTask
  readonly get: (taskId: string) => ExecTask | undefined
  readonly stop: (taskId: string) => Promise<ExecTask | undefined>
  readonly readTail: (taskId: string, lines: number) => Promise<ReadonlyArray<string> | undefined>
  readonly owned: () => ReadonlyArray<OwnedExecTask>
  readonly activity: () => ExecActivity
  readonly closeAll: () => void
}

export interface ExecActivity {
  readonly running: number
  readonly lastActiveAt?: Date
}

export interface OwnedExecTask {
  readonly taskId: string
  readonly owner: string
}

export interface ExecTasksOptions {
  readonly directory: string
  readonly shell: string
  readonly env: NodeJS.ProcessEnv
  readonly now?: () => Date
}

export const makeExecTasks = (options: ExecTasksOptions): ExecTasks => {
  const now = options.now ?? (() => new Date())
  const running = new Map<string, RunningTask>()
  const finished = new Map<string, ExecTask>()
  let lastFinishedAt: Date | undefined

  const launch = (command: ExecCommand | Omit<ExecCommand, "timeoutMs">): RunningTask => {
    const taskId = randomUUID()
    const outputPath = join(options.directory, `${taskId}.log`)
    mkdirSync(options.directory, { recursive: true })
    const child = spawnShell(options, command)
    const task = new RunningTask(taskId, command, child, outputPath, now)
    running.set(taskId, task)
    void task.done.then(() => {
      running.delete(taskId)
      finished.set(taskId, task.snapshot())
      lastFinishedAt = now()
    })
    return task
  }

  return {
    run: async (command) => {
      const task = launch(command)
      const timer = setTimeout(() => task.timeOut(), command.timeoutMs)
      await task.done
      clearTimeout(timer)
      return task.result()
    },
    start: (command, onFinish) => {
      const task = launch(command)
      void task.done.then(() => onFinish({ task: task.snapshot(), outputTail: task.tail() }))
      return task.snapshot()
    },
    get: (taskId) => running.get(taskId)?.snapshot() ?? finished.get(taskId),
    stop: async (taskId) => {
      const task = running.get(taskId)
      if (task === undefined) return finished.get(taskId)
      task.stop()
      await task.done
      return task.snapshot()
    },
    readTail: async (taskId, lines) => {
      const outputPath = (running.get(taskId)?.snapshot() ?? finished.get(taskId))?.outputPath
      if (outputPath === undefined) return undefined
      const text = await readFile(outputPath, "utf8").catch(() => "")
      return text
        .split("\n")
        .filter((line, index, all) => index < all.length - 1 || line !== "")
        .slice(-lines)
    },
    owned: () =>
      [...running.values()].flatMap((task) =>
        task.owner === undefined ? [] : [{ taskId: task.taskId, owner: task.owner }]
      ),
    activity: () => ({
      running: running.size,
      ...(lastFinishedAt === undefined ? {} : { lastActiveAt: lastFinishedAt })
    }),
    closeAll: () => {
      for (const task of running.values()) task.stop()
    }
  }
}

type ShellChild = ChildProcessByStdio<null, Readable, Readable>

const KILL_GRACE_MS = 2_000

const spawnShell = (
  options: ExecTasksOptions,
  command: Pick<ExecCommand, "command" | "cwd">
): ShellChild =>
  spawn(options.shell, ["-lc", command.command], {
    cwd: command.cwd,
    env: options.env,
    detached: true,
    stdio: ["ignore", "pipe", "pipe"]
  })

class RunningTask {
  readonly done: Promise<void>
  private readonly startedAt: Date
  private readonly log: WriteStream
  private readonly output = new OutputTail()
  private exitCode: number | null | undefined
  private finishedAt: Date | undefined
  private stopped = false
  private timedOut = false

  constructor(
    readonly taskId: string,
    private readonly command: ExecCommand | Omit<ExecCommand, "timeoutMs">,
    private readonly child: ShellChild,
    readonly outputPath: string,
    private readonly now: () => Date
  ) {
    this.startedAt = now()
    this.log = createWriteStream(outputPath)
    this.capture(child.stdout)
    this.capture(child.stderr)
    this.done = this.waitForExit()
  }

  get owner(): string | undefined {
    return this.command.owner
  }

  timeOut(): void {
    this.timedOut = true
    this.stop()
  }

  stop(): void {
    if (this.exitCode !== undefined) return
    this.stopped = true
    this.signal("SIGTERM")
    setTimeout(() => this.signal("SIGKILL"), KILL_GRACE_MS).unref()
  }

  tail(): string {
    return this.output.text()
  }

  snapshot(): ExecTask {
    return {
      taskId: this.taskId,
      command: this.command.command,
      description: this.command.description,
      cwd: this.command.cwd,
      state: this.state(),
      ...(this.exitCode === undefined ? {} : { exitCode: this.exitCode }),
      startedAt: this.startedAt.toISOString(),
      ...(this.finishedAt === undefined ? {} : { finishedAt: this.finishedAt.toISOString() }),
      outputPath: this.outputPath
    }
  }

  result(): ExecResult {
    return {
      exitCode: this.exitCode ?? null,
      output: this.output.text(this.outputPath),
      timedOut: this.timedOut,
      durationMs: (this.finishedAt ?? this.now()).getTime() - this.startedAt.getTime(),
      outputPath: this.outputPath
    }
  }

  private state(): ExecTask["state"] {
    if (this.exitCode === undefined) return "running"
    return this.stopped ? "stopped" : "exited"
  }

  private capture(stream: Readable): void {
    stream.on("data", (chunk: Buffer) => {
      this.log.write(chunk)
      this.output.append(chunk.toString("utf8"))
    })
  }

  private waitForExit(): Promise<void> {
    return new Promise((resolve) => {
      const finish = (code: number | null) => {
        if (this.exitCode !== undefined) return
        this.exitCode = code
        this.finishedAt = this.now()
        this.log.end(() => resolve())
      }
      this.child.once("error", (cause) => {
        this.output.append(`${cause.message}\n`)
        finish(null)
      })
      this.child.once("close", finish)
    })
  }

  private signal(signal: NodeJS.Signals): void {
    if (this.child.pid === undefined || this.child.exitCode !== null) return
    try {
      process.kill(-this.child.pid, signal)
    } catch {
      this.child.kill(signal)
    }
  }
}
