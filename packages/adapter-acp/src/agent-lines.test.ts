import { describe, expect, it } from "vitest"

import { rewriteAgentLines } from "./agent-lines.js"

const stream = (chunks: ReadonlyArray<string>): ReadableStream<Uint8Array> => {
  const encoder = new TextEncoder()
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk))
      controller.close()
    }
  })
}

const read = async (input: ReadableStream<Uint8Array>): Promise<string> =>
  new Response(input).text()

describe("rewriteAgentLines", () => {
  it("rewrites whole lines, even when a message arrives split across chunks", async () => {
    const rewritten = rewriteAgentLines(
      stream(['{"method":"a"}\n{"meth', 'od":"b"}\n{"method":"c"}']),
      (line) => line.replace('"b"', '"B"')
    )
    expect(await read(rewritten)).toBe('{"method":"a"}\n{"method":"B"}\n{"method":"c"}')
  })

  it("keeps multi-byte characters intact across chunk boundaries", async () => {
    const bytes = new TextEncoder().encode('{"text":"é"}\n')
    const input = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(bytes.slice(0, 10))
        controller.enqueue(bytes.slice(10))
        controller.close()
      }
    })
    expect(await read(rewriteAgentLines(input, (line) => line))).toBe('{"text":"é"}\n')
  })
})
