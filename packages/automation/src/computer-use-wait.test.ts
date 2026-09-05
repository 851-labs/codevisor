import { describe, expect, it } from "vitest"
import { computerUseState, waitForComputerState } from "./computer-use-wait.js"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
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
    expect(computerUseState(timed)).toMatchObject({ matched: false, text: "Current state" })
  })
  it("rejects invalid conditions and propagates observation failures", async () => {
    const observe = async () => reply("")
    for (const args of [
      { app: "a" },
      { text: "" },
      { role: "" },
      { text: "x", timeout_ms: -1 },
      { text: "x", state: "maybe" }
    ]) {
      await expect(waitForComputerState(args, observe, clock())).rejects.toThrow()
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

  it("uses the real polling clock and tolerates an observation with no text", async () => {
    let reads = 0
    const result = await waitForComputerState({ text: "Ready", timeout_ms: 1000 }, async () =>
      ++reads === 1 ? { content: [{ type: "text", text: '{"windows":[]}' }] } : reply("Ready")
    )
    expect(computerUseState(result).matched).toBe(true)
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
