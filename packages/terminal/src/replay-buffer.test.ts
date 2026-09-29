import type { TerminalServerFrame } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { ReplayBuffer } from "./replay-buffer.js"

const output = (seq: number, data: string): TerminalServerFrame => ({ type: "output", seq, data })

describe("ReplayBuffer", () => {
  it("replays frames after a cursor and trims the oldest past the byte budget", () => {
    const buffer = new ReplayBuffer(10)
    expect(buffer.firstSeq).toBeUndefined()
    expect(buffer.since(0)).toEqual([])

    buffer.push(output(1, "aaaa"))
    buffer.push(output(2, "bbbb"))
    expect(buffer.since(0).map((frame) => frame.seq)).toEqual([1, 2])
    expect(buffer.since(1).map((frame) => frame.seq)).toEqual([2])
    expect(buffer.since(2)).toEqual([])

    // Multi-byte text is measured in UTF-8 bytes: "éé" is 4 bytes.
    buffer.push(output(3, "éé"))
    expect(buffer.firstSeq).toBe(2)
    expect(buffer.bytes).toBe(8)
    // A cursor older than the retained window returns everything retained.
    expect(buffer.since(0).map((frame) => frame.seq)).toEqual([2, 3])
  })

  it("always keeps the newest frame and counts control frames", () => {
    const buffer = new ReplayBuffer(4)
    buffer.push(output(1, "a"))
    buffer.push(output(2, "much too large"))
    expect(buffer.since(0).map((frame) => frame.seq)).toEqual([2])
    buffer.push({ type: "exit", seq: 3 })
    expect(buffer.since(0)).toEqual([{ type: "exit", seq: 3 }])
    expect(buffer.length).toBe(1)
  })

  it("compacts after trimming many frames without losing order", () => {
    const buffer = new ReplayBuffer(100)
    for (let seq = 1; seq <= 5000; seq += 1) buffer.push(output(seq, "0123456789"))
    expect(buffer.length).toBe(10)
    expect(buffer.since(4995).map((frame) => frame.seq)).toEqual([4996, 4997, 4998, 4999, 5000])
  })
})
