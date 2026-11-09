import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, expect, it } from "vitest"

import { runOwnedTask } from "./owned-task.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  process.exitCode = undefined
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

async function script(body: string) {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-owned-task-"))
  cleanups.push(() => rm(directory, { recursive: true, force: true }))
  const path = join(directory, "task.mjs")
  await writeFile(path, body)
  return path
}

it("passes the task's exit code through", async () => {
  expect(await runOwnedTask(await script("process.exit(Number(process.argv[2]))"), ["3"])).toBe(3)
  expect(process.exitCode).toBe(3)
})

it("asks the task to stop by closing its stdin when the launcher is signalled", async () => {
  const listeners = process.listenerCount("SIGTERM")
  const task = runOwnedTask(
    await script(
      `process.stdin.resume(); process.stdin.on("end", () => process.exit(0)); process.stdout.write("")`
    ),
    []
  )
  await new Promise((resolve) => setTimeout(resolve, 200))
  process.emit("SIGTERM", "SIGTERM")

  expect(await task).toBe(0)
  expect(process.listenerCount("SIGTERM")).toBe(listeners)
})
