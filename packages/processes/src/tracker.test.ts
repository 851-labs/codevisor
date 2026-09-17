import { afterEach, beforeEach, expect, it, onTestFinished, vi } from "vitest"

import { trackProcessTree, type ProcessIdentity } from "./index.mjs"

const entry = (pid: number, ppid = 1, pgid = pid, startedAt = "first"): ProcessIdentity => ({
  pid,
  ppid,
  pgid,
  startedAt,
  state: "S"
})

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

const fixture = async (initial: ProcessIdentity[], detached = false) => {
  let table = initial
  const list = vi.fn(async () => table)
  const stop = vi.fn(async (_entries: ProcessIdentity[]) => {})
  const tree = await trackProcessTree(30, { list, stop, detached })
  onTestFinished(() => tree.dispose())
  return {
    tree,
    list,
    stop,
    set: (next: ProcessIdentity[]) => {
      table = next
    }
  }
}

it("retains only compact, current identities through repeated command churn", async () => {
  const root = entry(30)
  let commandReads = 0
  const withCommand = {
    ...root,
    get command() {
      commandReads++
      return "a command whose backing storage must never enter the tracker"
    }
  }
  const f = await fixture([withCommand])
  for (let pid = 100; pid < 1100; pid++) {
    f.set([
      withCommand,
      { ...entry(pid, 30, 30), command: "short-lived command" } as ProcessIdentity
    ])
    await vi.advanceTimersByTimeAsync(250)
  }
  await f.tree.stop()
  expect(commandReads).toBe(0)
  expect(f.stop).toHaveBeenCalledWith([root, entry(1099, 30, 30)], {})
})

it("prunes dead identities before their PIDs are reused in another tree", async () => {
  const f = await fixture([entry(30), entry(31, 30, 31)])
  f.set([entry(30)])
  await vi.advanceTimersByTimeAsync(250)
  f.set([entry(30), entry(31, 90, 90, "reused"), entry(32, 31, 90, "new")])
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([entry(30)], {})
})

it("follows a reparented child and discovers its new descendants before pruning", async () => {
  const f = await fixture([entry(30, 1, 90), entry(31, 30, 31)])
  f.set([entry(32, 31, 31), entry(31, 1, 31), entry(90)])
  await vi.advanceTimersByTimeAsync(250)
  f.set([entry(32, 1, 31), entry(90)])
  await f.tree.stop({ includeRoot: false })
  expect(f.stop).toHaveBeenCalledWith([entry(32, 1, 31)], { includeRoot: false })
})

it("finds orphaned members of a dedicated group even after every known process exits", async () => {
  const f = await fixture([entry(30)])
  f.set([entry(32, 1, 30), entry(90)])
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([entry(32, 1, 30)], {})
})

it("captures a detached group when its owner already exited before tracking began", async () => {
  const f = await fixture([entry(32, 1, 30)], true)
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([entry(32, 1, 30)], {})
})

it("keeps group children while their leader is a zombie, without retaining zombies", async () => {
  const f = await fixture([entry(30), { ...entry(31, 30, 30), state: "Z" }])
  f.set([{ ...entry(30), state: "Z+" }, entry(32, 1, 30)])
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([entry(32, 1, 30)], {})
})

it("never adopts a reused group leader or its children", async () => {
  const f = await fixture([entry(30), entry(31, 30, 31)])
  f.set([entry(30, 1, 30, "reused"), entry(32, 30, 30), entry(31, 1, 31)])
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([entry(31, 1, 31)], {})
})

it("retires an empty group instead of adopting a later group with the same number", async () => {
  const f = await fixture([entry(30)])
  f.set([])
  await vi.advanceTimersByTimeAsync(250)
  f.set([entry(32, 1, 30)])
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([], {})
})

it("does not create a group claim when the first snapshot has no owned processes", async () => {
  const f = await fixture([], true)
  f.set([entry(30, 1, 30, "unrelated"), entry(32, 30, 30)])
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([], {})
})

it("waits for a slow scan to finish before scheduling the next poll", async () => {
  const f = await fixture([entry(30)])
  const pending = Promise.withResolvers<ProcessIdentity[]>()
  f.list.mockImplementationOnce(() => pending.promise)
  await vi.advanceTimersByTimeAsync(250)
  expect(f.list).toHaveBeenCalledTimes(2)
  await vi.advanceTimersByTimeAsync(60_000)
  expect(f.list).toHaveBeenCalledTimes(2)
  expect(vi.getTimerCount()).toBe(0)
  pending.resolve([entry(30)])
  await vi.advanceTimersByTimeAsync(0)
  expect(vi.getTimerCount()).toBe(1)
  await vi.advanceTimersByTimeAsync(249)
  expect(f.list).toHaveBeenCalledTimes(2)
  await vi.advanceTimersByTimeAsync(1)
  expect(f.list).toHaveBeenCalledTimes(3)
})

it.each(["stop", "dispose"] as const)(
  "%s during a scan prevents further polling without losing shutdown ownership",
  async (action) => {
    const f = await fixture([entry(30)])
    const pending = Promise.withResolvers<ProcessIdentity[]>()
    f.list.mockImplementationOnce(() => pending.promise)
    await vi.advanceTimersByTimeAsync(250)
    const finishing = f.tree[action]()
    f.set([entry(31, 1, 30)])
    pending.resolve([entry(30), entry(31, 30, 30)])
    await finishing
    await vi.advanceTimersByTimeAsync(60_000)
    expect(vi.getTimerCount()).toBe(0)
    await f.tree.stop()
    expect(f.list).toHaveBeenCalledTimes(3)
    expect(f.stop).toHaveBeenCalledWith([entry(31, 1, 30)], {})
  }
)

it("retries shutdown after a failed final scan", async () => {
  const f = await fixture([entry(30)])
  f.list.mockRejectedValueOnce(new Error("ps failed"))
  await expect(f.tree.stop()).rejects.toThrow("ps failed")
  await f.tree.stop()
  expect(f.stop).toHaveBeenCalledWith([entry(30)], {})
  expect(vi.getTimerCount()).toBe(0)
})
