import { mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import { tempDirs } from "../test-support.js"
import { EXEC_OUTPUT_LIMIT } from "./exec-output-tail.js"
import { makeExecTasks, type FinishedExecTask } from "./exec-tasks.js"

const tasksIn = () => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-exec-"))
  tempDirs.push(directory)
  const home = mkdtempSync(join(tmpdir(), "codevisor-exec-home-"))
  tempDirs.push(home)
  const tasks = makeExecTasks({ directory, shell: "/bin/sh", env: { ...process.env, HOME: home } })
  onTestFinished(() => tasks.closeAll())
  return { tasks, directory }
}

const finishedTask = () => {
  const { promise, resolve } = Promise.withResolvers<FinishedExecTask>()
  return { finished: promise, onFinish: resolve }
}

describe("exec tasks", () => {
  it("runs a command in a folder and returns its combined output and exit code", async () => {
    const { tasks, directory } = tasksIn()

    const result = await tasks.run({
      command: "pwd; echo oops >&2; exit 3",
      description: "test",
      cwd: directory,
      timeoutMs: 30_000
    })

    expect(result.exitCode).toBe(3)
    expect(result.timedOut).toBe(false)
    expect(result.output).toContain(directory.split("/").at(-1))
    expect(result.output).toContain("oops")
    expect(readFileSync(result.outputPath, "utf8")).toBe(result.output)
  })

  it("keeps only the end of very long output and points at the full log", async () => {
    const { tasks, directory } = tasksIn()

    const result = await tasks.run({
      command: `head -c ${EXEC_OUTPUT_LIMIT + 5000} /dev/zero | tr '\\0' 'x'; echo END`,
      description: "long",
      cwd: directory,
      timeoutMs: 30_000
    })

    expect(result.output).toMatch(/^\[\d+ earlier characters cut; the full output is in /)
    expect(result.output.endsWith("END\n")).toBe(true)
    expect(readFileSync(result.outputPath, "utf8").length).toBe(EXEC_OUTPUT_LIMIT + 5004)
  })

  it("stops a command that runs past its timeout", async () => {
    const { tasks, directory } = tasksIn()

    const result = await tasks.run({
      command: "sleep 30",
      description: "slow",
      cwd: directory,
      timeoutMs: 50
    })

    expect(result.timedOut).toBe(true)
    expect(result.exitCode).not.toBe(0)
  })

  it("runs background tasks until they exit or are stopped", async () => {
    const { tasks, directory } = tasksIn()
    const quick = finishedTask()
    const slow = finishedTask()

    const started = tasks.start(
      { command: "echo started; exit 0", description: "quick", cwd: directory },
      quick.onFinish
    )
    const long = tasks.start(
      { command: "echo waiting; sleep 30", description: "server", cwd: directory },
      slow.onFinish
    )

    expect(started.state).toBe("running")
    const done = await quick.finished
    expect(done.task).toMatchObject({ taskId: started.taskId, state: "exited", exitCode: 0 })
    expect(done.outputTail).toBe("started\n")
    expect(tasks.get(started.taskId)?.state).toBe("exited")

    const stopped = await tasks.stop(long.taskId)
    expect(stopped?.state).toBe("stopped")
    expect((await slow.finished).task.state).toBe("stopped")
    expect(await tasks.stop("missing")).toBeUndefined()
  })
})
