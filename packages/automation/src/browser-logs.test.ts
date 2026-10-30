import { describe, expect, it, vi } from "vitest"

import {
  browserToolSessionState,
  fakeBrowserRuntime,
  fakeBrowserToolInvocation
} from "./browser-runtime-test-support.js"
import { invokePageTools } from "./browser-use-invoke-page.js"

function fixture(entries: Array<Readonly<Record<string, unknown>>>) {
  const logs = new Map([
    ["page", entries],
    ["other", [{ timestamp: Infinity }]]
  ])
  const read = async (args: Readonly<Record<string, unknown>> = {}) => {
    const result = await invokePageTools(
      fakeBrowserToolInvocation({
        active: fakeBrowserRuntime({ logs }),
        backend: "managed",
        args,
        toolName: "dev.logs"
      }),
      browserToolSessionState()
    )
    const content = result!.content[0]!
    if (content.type !== "text") throw new Error("Expected JSON text")
    return JSON.parse(content.text).entries
  }
  return { read, logs }
}

describe("dev.logs normalization", () => {
  it("normalizes mixed protocol records without consuming history", async () => {
    const entries = [
      {
        method: "Runtime.consoleAPICalled",
        type: "warning",
        timestamp: "2000",
        args: [
          { value: 0 },
          { value: false },
          { value: "" },
          { value: null, description: "object" },
          { description: null, type: "undefined" },
          {}
        ]
      },
      { method: "Runtime.consoleAPICalled", timestamp: false, args: {} },
      {
        method: "Log.entryAdded",
        entry: { level: "warning", text: false, timestamp: "", url: "https://example.com" }
      },
      { method: "Log.entryAdded", entry: [] },
      {
        method: "Runtime.exceptionThrown",
        timestamp: 0,
        exceptionDetails: {
          text: "fallback",
          exception: { description: "Error: broken" },
          url: "page.js"
        }
      },
      {
        method: "unexpected",
        timestamp: 0,
        exceptionDetails: { text: 0, exception: null, url: 42 }
      },
      { timestamp: 0, exceptionDetails: null },
      { method: "Log.entryAdded", entry: null },
      {
        method: "Runtime.consoleAPICalled",
        type: 7,
        timestamp: 0,
        args: [{ value: null, description: null, type: null }]
      },
      { timestamp: 0, exceptionDetails: { exception: [], text: "" } }
    ]
    const clock = vi.spyOn(Date, "now").mockReturnValue(0)
    try {
      const { read, logs } = fixture(entries)
      const expected = [
        {
          level: "warn",
          message: "0 false  object undefined ",
          timestamp: "1970-01-01T00:00:02.000Z"
        },
        { level: "log", message: "", timestamp: "1970-01-01T00:00:00.000Z" },
        {
          level: "warn",
          message: "false",
          timestamp: "1970-01-01T00:00:00.000Z",
          url: "https://example.com"
        },
        { level: "log", message: "", timestamp: "1970-01-01T00:00:00.000Z" },
        {
          level: "error",
          message: "Error: broken",
          timestamp: "1970-01-01T00:00:00.000Z",
          url: "page.js"
        },
        { level: "error", message: "0", timestamp: "1970-01-01T00:00:00.000Z" },
        { level: "error", message: "Uncaught page error", timestamp: "1970-01-01T00:00:00.000Z" },
        { level: "log", message: "", timestamp: "1970-01-01T00:00:00.000Z" },
        { level: "7", message: "", timestamp: "1970-01-01T00:00:00.000Z" },
        { level: "error", message: "", timestamp: "1970-01-01T00:00:00.000Z" }
      ]
      expect(await read()).toEqual(expected)
      expect(await read()).toEqual(expected)
      expect(logs.get("page")).toBe(entries)
      expect(entries).toHaveLength(10)
    } finally {
      clock.mockRestore()
    }
  })

  it("filters literal levels and case-sensitive messages before taking the last insertion-ordered entries", async () => {
    const { read } = fixture([
      {
        method: "Runtime.consoleAPICalled",
        type: "warning",
        timestamp: 3000,
        args: [{ value: "Keep first" }]
      },
      { method: "Log.entryAdded", entry: { level: "warn", text: "keep lower", timestamp: 9000 } },
      {
        method: "Runtime.consoleAPICalled",
        type: "warn",
        timestamp: 1000,
        args: [{ value: "Keep last" }]
      },
      {
        method: "Runtime.consoleAPICalled",
        type: "CUSTOM",
        timestamp: 0,
        args: [{ value: "Other" }]
      }
    ])
    expect(await read({ levels: ["warning"], filter: "Keep", limit: 1 })).toEqual([
      { level: "warn", message: "Keep last", timestamp: "1970-01-01T00:00:01.000Z" }
    ])
    expect(await read({ levels: [] })).toEqual([])
    expect(await read({ levels: ["CUSTOM"] })).toEqual([
      { level: "CUSTOM", message: "Other", timestamp: "1970-01-01T00:00:00.000Z" }
    ])
    expect(await read({ levels: ["custom"] })).toEqual([])
    for (const levels of [["error", 1], "error", null]) {
      expect(await read({ levels, filter: new String("missing") })).toHaveLength(4)
    }
    expect(await read({ filter: "KEEP" })).toEqual([])
  })

  it("stamps console, log and exception entries without a timestamp with the read time", async () => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(3000)
    try {
      const { read } = fixture([
        { method: "Runtime.consoleAPICalled", args: [] },
        { method: "Log.entryAdded", entry: { timestamp: null } },
        { timestamp: null, exceptionDetails: { text: "kept" } }
      ])
      expect((await read()).map((entry: { timestamp: string }) => entry.timestamp)).toEqual([
        "1970-01-01T00:00:03.000Z",
        "1970-01-01T00:00:03.000Z",
        "1970-01-01T00:00:03.000Z"
      ])
    } finally {
      clock.mockRestore()
    }
  })

  it("returns the last 100 entries by default and clamps numeric limits to 1 through 1000", async () => {
    const { read } = fixture(
      Array.from({ length: 1002 }, (_, index) => ({
        timestamp: 0,
        exceptionDetails: { text: String(index) }
      }))
    )
    const defaults = await read()
    expect(defaults).toHaveLength(100)
    expect(defaults[0]).toEqual({
      level: "error",
      message: "902",
      timestamp: "1970-01-01T00:00:00.000Z"
    })
    for (const limit of [0, -5, false, "", 1.9]) {
      expect(await read({ limit })).toEqual([
        { level: "error", message: "1001", timestamp: "1970-01-01T00:00:00.000Z" }
      ])
    }
    expect(await read({ limit: "2.9" })).toEqual([
      { level: "error", message: "1000", timestamp: "1970-01-01T00:00:00.000Z" },
      { level: "error", message: "1001", timestamp: "1970-01-01T00:00:00.000Z" }
    ])
    const bounded = await read({ limit: Infinity })
    expect(bounded).toHaveLength(1000)
    expect(bounded[0].message).toBe("2")
    expect(await read({ limit: null })).toHaveLength(100)
    const empty = fixture([])
    empty.logs.delete("page")
    expect(await empty.read()).toEqual([])
  })
})
