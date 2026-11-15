import { describe, expect, it } from "vitest"

import { makeShutdownHooks } from "./shutdown-hooks.js"

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
})
