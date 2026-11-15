import { spawnSync } from "node:child_process"

import { describe, expect, it } from "vitest"

import { makeShutdownHooks } from "./shutdown-hooks.js"

const moduleUrl = new URL("./shutdown-hooks.ts", import.meta.url).href

const exitStatusOf = (setup: string): number | null =>
  spawnSync(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `import { processShutdown } from ${JSON.stringify(moduleUrl)}\n${setup}`
    ],
    { encoding: "utf8", timeout: 10_000 }
  ).status

const deferred = (): { promise: Promise<void>; resolve: () => void } => {
  let resolve!: () => void
  const promise = new Promise<void>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

describe("makeShutdownHooks", () => {
  it("exits after every hook settles, including one that fails", async () => {
    const exits: number[] = []
    const order: string[] = []
    const closing = deferred()
    const hooks = makeShutdownHooks({
      exit: (code) => exits.push(code),
      wait: () => new Promise(() => undefined)
    })
    hooks.add(async () => {
      await closing.promise
      order.push("tunnel closed")
    })
    hooks.add(() => Promise.reject(new Error("already gone")))

    const exiting = hooks.exit(143)
    await Promise.resolve()
    expect(exits).toEqual([])
    closing.resolve()
    await exiting

    expect(order).toEqual(["tunnel closed"])
    expect(exits).toEqual([143])
  })

  it("exits when the time limit passes even if a hook never settles", async () => {
    const exits: number[] = []
    const limit = deferred()
    const waited: number[] = []
    const hooks = makeShutdownHooks({
      exit: (code) => exits.push(code),
      limitMs: 500,
      wait: (ms) => {
        waited.push(ms)
        return limit.promise
      }
    })
    hooks.add(() => new Promise(() => undefined))

    const exiting = hooks.exit(0)
    limit.resolve()
    await exiting

    expect(waited).toEqual([500])
    expect(exits).toEqual([0])
  })

  it("runs the hooks and exits only once when several exit paths fire", async () => {
    const exits: number[] = []
    let runs = 0
    const hooks = makeShutdownHooks({
      exit: (code) => exits.push(code),
      wait: () => new Promise(() => undefined)
    })
    hooks.add(async () => {
      runs += 1
    })

    await Promise.all([hooks.exit(143), hooks.exit(0)])

    expect(runs).toBe(1)
    expect(exits).toEqual([143])
  })

  it("exits with the requested code when a hook never settles and nothing else keeps the process alive", () => {
    expect(
      exitStatusOf(
        "processShutdown.add(() => new Promise(() => undefined))\nvoid processShutdown.exit(85)"
      )
    ).toBe(85)
  })

  it("exits with the requested code when the only thing left is an unreferenced timer", () => {
    expect(
      exitStatusOf(
        "processShutdown.add(() => new Promise((resolve) => setTimeout(resolve, 5_000).unref()))\nvoid processShutdown.exit(85)"
      )
    ).toBe(85)
  })
})
