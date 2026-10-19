import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it, vi } from "vitest"

import { computerUseState, waitForComputerState } from "./computer-use-wait.js"
const reply = (text: string): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify({ snapshotId: text, text }) }]
})
const clock = () => {
  let time = 0
  return {
    now: () => time,
    sleep: async (ms: number) => {
      time += ms
    }
  }
}

afterEach(() => vi.useRealTimers())

const observeNothing = async () => reply("")

describe("Computer Use waits", () => {
  it("waits for a menu using accessibility-only reads and captures one final screenshot", async () => {
    const calls: Record<string, unknown>[] = []
    const result = await waitForComputerState(
      { app: "Music", text: "Add to Playlist", role: "AXMenuItem", screenshot: true },
      async (args) => {
        calls.push(args)
        return reply(calls.length === 1 ? "1 AXWindow Music" : "2 AXMenuItem Add to Playlist")
      },
      clock()
    )
    expect(computerUseState(result).matched).toBe(true)
    expect(calls.map((c) => c.screenshot)).toEqual([false, false, true])
    expect(calls.every((c) => c.disableDiff === true)).toBe(true)
  })
  it("cuts a wait short to fit the execute budget and reports the shorter wait", async () => {
    const reads: Array<number> = []
    const time = clock()
    const result = await waitForComputerState(
      { app: "Music", text: "Never", timeout_ms: 30_000 },
      async () => {
        reads.push(time.now())
        return reply("Current state")
      },
      time,
      undefined,
      5_000
    )
    expect(computerUseState(result)).toMatchObject({
      matched: false,
      text: "Current state",
      waitError: "The requested state did not appear within 3500ms",
      clampedToMs: 3_500
    })
    expect(reads.at(-1)).toBe(3_500)
  })
  it("doesn't shrink a wait to nothing when the execute budget is already spent", async () => {
    const result = await waitForComputerState(
      { app: "Music", text: "Never", timeout_ms: 400 },
      async () => reply("Current state"),
      clock(),
      undefined,
      0
    )
    expect(computerUseState(result)).toMatchObject({
      matched: false,
      waitError: "The requested state did not appear within 400ms"
    })
    expect(computerUseState(result).clampedToMs).toBeUndefined()
  })
  it("waits for a dialog to disappear and returns the last state on timeout", async () => {
    let reads = 0
    expect(
      computerUseState(
        await waitForComputerState(
          { app: "Music", role: "AXSheet", state: "absent" },
          async () => reply(++reads === 1 ? "1 AXSheet Create" : "2 AXWindow Music"),
          clock()
        )
      ).matched
    ).toBe(true)
    const timed = await waitForComputerState(
      { app: "Music", text: "Not here", timeout_ms: 0 },
      async () => reply("Current state"),
      clock()
    )
    expect(computerUseState(timed)).toMatchObject({
      matched: false,
      text: "Current state",
      waitError: "The requested state did not appear within 0ms"
    })
    const stillOpen = await waitForComputerState(
      { app: "Music", role: "AXSheet", state: "absent", timeout_ms: 0 },
      async () => reply("1 AXSheet Create"),
      clock()
    )
    expect(computerUseState(stillOpen)).toMatchObject({
      matched: false,
      waitError: "The requested state was still present after 0ms"
    })
  })
  it("waits for accessibility changes between reads and falls back to polling when unavailable", async () => {
    const time = clock()
    const waits: number[] = []
    let reads = 0
    const changed = await waitForComputerState(
      { app: "Music", role: "AXSheet", timeout_ms: 2000 },
      async () => reply(++reads < 3 ? "1 AXWindow Music" : "2 AXSheet Create"),
      time,
      async (ms) => {
        waits.push(ms)
      }
    )
    expect(computerUseState(changed).matched).toBe(true)
    expect(waits).toEqual([500, 500])
    const sleeps: number[] = []
    let attempts = 0
    const fallback = await waitForComputerState(
      { app: "Music", text: "Never", timeout_ms: 600 },
      async () => reply("1 AXWindow Music"),
      {
        now: time.now,
        sleep: async (ms) => {
          sleeps.push(ms)
          await time.sleep(ms)
        }
      },
      async () => {
        attempts += 1
        throw new Error("Unsupported Computer Use tool: await_change")
      }
    )
    expect(computerUseState(fallback).matched).toBe(false)
    expect(attempts).toBe(1)
    expect(sleeps).toEqual([200, 200, 200])
  })
  it("rejects invalid conditions and propagates observation failures", async () => {
    for (const args of [
      { app: "a" },
      { text: "" },
      { role: "" },
      { text: "x", timeout_ms: -1 },
      { text: "x", state: "maybe" }
    ]) {
      await expect(waitForComputerState(args, observeNothing, clock())).rejects.toThrow()
    }
    await expect(
      waitForComputerState(
        { text: "x" },
        async () => ({ isError: true, content: [{ type: "text", text: "Disconnected" }] }),
        clock()
      )
    ).rejects.toThrow("Disconnected")
    expect(() => computerUseState({ content: [] })).toThrow("no state")
    expect(() => computerUseState({ content: [{ type: "text", text: "null" }] })).toThrow(
      "invalid state"
    )
  })

  it("requires role and text on the same row and rechecks after capturing pixels", async () => {
    const states = [
      "1 AXTextField Song\n2 AXMenuItem Other",
      "2 AXMenuItem Song",
      "3 AXWindow Loading",
      "2 AXMenuItem Song",
      "2 AXMenuItem Song"
    ]
    let reads = 0
    const result = await waitForComputerState(
      { text: "Song", role: "AXMenuItem", screenshot: true },
      async () => reply(states[reads++]!),
      clock()
    )
    expect(computerUseState(result).matched).toBe(true)
    expect(reads).toBe(5)
  })

  it("uses the default scheduler and tolerates an observation with no text", async () => {
    vi.useFakeTimers()
    let reads = 0
    const completed = vi.fn()
    const operation = waitForComputerState({ text: "Ready", timeout_ms: 1000 }, async () =>
      ++reads === 1 ? { content: [{ type: "text", text: '{"windows":[]}' }] } : reply("Ready")
    )
    const settled = operation.then(completed)
    await vi.advanceTimersByTimeAsync(199)
    expect(completed).not.toHaveBeenCalled()
    expect(reads).toBe(1)
    await vi.advanceTimersByTimeAsync(1)
    await settled
    expect(computerUseState(completed.mock.calls[0]![0]).matched).toBe(true)
    expect(reads).toBe(2)
  })

  it("matches Linux roles containing spaces without matching a parent role", async () => {
    const result = await waitForComputerState(
      { role: "menu item", text: "Add" },
      async () => reply("3 menu_item Add to Playlist"),
      clock()
    )
    expect(computerUseState(result).matched).toBe(true)
    const absent = await waitForComputerState(
      { role: "menu", timeout_ms: 0 },
      async () => reply("3 menu_item Add to Playlist"),
      clock()
    )
    expect(computerUseState(absent).matched).toBe(false)
  })
})
