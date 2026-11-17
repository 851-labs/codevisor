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

const reportsAncestry = `
import { execFileSync } from "node:child_process"
const launcher = Number(process.argv[2])
const parentOf = (pid) => Number(execFileSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8" }))
const descendsFromLauncher = () => {
  for (let pid = process.pid; pid > 1; pid = parentOf(pid)) if (pid === launcher) return true
  return false
}
process.stdin.resume()
process.stdin.on("end", () => process.exit(descendsFromLauncher() ? 9 : 0))
`

it("passes the task's exit code through", async () => {
  expect(await runOwnedTask(await script("process.exit(Number(process.argv[2]))"), ["3"])).toBe(3)
  expect(process.exitCode).toBe(3)
})

it("runs the task outside the launcher's process tree and stops it by closing its stdin", async () => {
  const listeners = process.listenerCount("SIGTERM")
  const task = runOwnedTask(await script(reportsAncestry), [String(process.pid)])
  process.emit("SIGTERM", "SIGTERM")

  expect(await task).toBe(0)
  expect(process.listenerCount("SIGTERM")).toBe(listeners)
})
