import { describe, expect, it } from "vitest"

import { JsonHistoryFilter } from "./json-history-filter.js"

describe("Codex history filtering", () => {
  it("preserves metadata and unrelated arrays at every chunk boundary", () => {
    const input =
      JSON.stringify({
        id: 4,
        result: {
          thread: {
            id: "thread",
            turns: [{ text: 'escaped \\" [ ] { } 😀', nested: [1, 2] }],
            name: "chat"
          },
          model: "codex"
        },
        other: { thread: { turns: ["keep"] } }
      }) +
      "\n" +
      JSON.stringify({
        method: "item/completed",
        params: { item: { turns: ["real tool content"] } }
      }) +
      "\n"
    const expected = input.replace(
      JSON.stringify([{ text: 'escaped \\" [ ] { } 😀', nested: [1, 2] }]),
      "[]"
    )
    for (let size = 1; size <= input.length; size++) {
      const filter = new JsonHistoryFilter()
      const output: string[] = []
      for (let index = 0; index < input.length; index += size)
        output.push(filter.push(input.slice(index, index + size)))
      expect(output.join("")).toBe(expected)
    }
  })

  it("never retains or forwards the growing history prefix", () => {
    const filter = new JsonHistoryFilter()
    expect(filter.push('{"result":{"thread":{"turns":[')).toBe('{"result":{"thread":{"turns":[]')
    const retainedBytes = JSON.stringify(filter).length
    const chunk = JSON.stringify({ output: "x".repeat(1024) }) + ","
    // Inspect retained state directly: a large throughput fixture only tests
    // runner speed under coverage and doesn't detect a hidden history buffer.
    for (let index = 0; index < 64; index++) {
      expect(filter.push(chunk)).toBe("")
      expect(JSON.stringify(filter).length).toBeLessThanOrEqual(retainedBytes)
    }
    expect(filter.push('null],"id":"chat"}},"id":1}\n')).toBe(',"id":"chat"}},"id":1}\n')
    expect(filter.push('{"method":"turn/started","params":{"id":"new"}}\n')).toBe(
      '{"method":"turn/started","params":{"id":"new"}}\n'
    )
  })
  it("bounds malformed and oversized key tokens without suppressing unrelated data", () => {
    expect(new JsonHistoryFilter().push('[{"key":[{}]}]\n')).toBe('[{"key":[{}]}]\n')
    for (const key of ['"\\q"', JSON.stringify("x".repeat(600))]) {
      const input = `{${key}:[1,2],"ok":true}\n`
      expect(new JsonHistoryFilter().push(input)).toBe(input)
    }
    const input = '{"params":{"thread":{"turns":[{"nested":[{}]}],"id":"t"}}}\n'
    expect(new JsonHistoryFilter().push(input)).toBe(
      '{"params":{"thread":{"turns":[],"id":"t"}}}\n'
    )
  })
})
