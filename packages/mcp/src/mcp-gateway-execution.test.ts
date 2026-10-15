import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  appIcon,
  EXECUTION_EMIT_INTERVAL_MS,
  errorSummary,
  executionCallIcon,
  executionFiles,
  humanizeToolName,
  makeExecutionRecorder,
  reportSkillRead,
  siteIcon,
  type ExecutionTimers
} from "./mcp-gateway-execution.js"
import { executionOf } from "./mcp-manager-test-support.js"

const manualTimers = () => {
  let now = 0
  const scheduled = new Map<number, { at: number; callback: () => void }>()
  let nextId = 0
  const timers: ExecutionTimers = {
    now: () => now,
    setTimeout: (callback, ms) => {
      nextId += 1
      const id = nextId
      scheduled.set(id, { at: now + ms, callback })
      return () => {
        scheduled.delete(id)
      }
    }
  }
  const advance = (ms: number): void => {
    now += ms
    for (const [id, timer] of scheduled) {
      if (timer.at > now) continue
      scheduled.delete(id)
      timer.callback()
    }
  }
  return { advance, scheduledCount: () => scheduled.size, timers }
}

const recording = (timers?: ExecutionTimers) => {
  const events: Array<RuntimeEvent> = []
  const recorder = makeExecutionRecorder({
    sink: (event) => {
      events.push(event)
    },
    sessionId: "session-1",
    argsHash: "hash-1",
    ...(timers === undefined ? {} : { timers })
  })
  const states = () => events.map(executionOf)
  return { events, recorder, states }
}

describe("skill read reports", () => {
  it("reach the session sink, and never fail the read", async () => {
    const events: Array<RuntimeEvent> = []
    await reportSkillRead((event) => void events.push(event), "session-1", {
      name: "deploy",
      ok: true
    })
    expect(events).toEqual([
      {
        kind: "session.output",
        subjectId: "session-1",
        payload: { kind: "codevisor_skill", skill: { name: "deploy", ok: true } }
      }
    ])
    await reportSkillRead(undefined, "session-1", { ok: true })
    await expect(
      reportSkillRead(
        () => {
          throw new Error("sink closed")
        },
        "session-1",
        { ok: true }
      )
    ).resolves.toBeUndefined()
  })
})

const labeledRecorder = (description: string) => {
  const events: Array<RuntimeEvent> = []
  const recorder = makeExecutionRecorder({
    sink: (event) => {
      events.push(event)
    },
    sessionId: "session-1",
    argsHash: "hash-1",
    description
  })
  return { recorder, events }
}

describe("execution recorder", () => {
  it("carries the workflow's label, one line and short", async () => {
    const { recorder, events } = labeledRecorder("\n  List my machines\nand more detail")
    await recorder.finish()
    expect(events.map(executionOf)).toEqual([
      { state: "running", description: "List my machines", calls: [] },
      { state: "completed", description: "List my machines", calls: [] }
    ])
    const long = labeledRecorder("x".repeat(200))
    expect(executionOf(long.events[0]!)).toMatchObject({ description: `${"x".repeat(79)}…` })
    const blank = labeledRecorder("  \n ")
    expect(executionOf(blank.events[0]!)).toEqual({
      state: "running",
      calls: []
    })
  })

  it("emits the start at once, throttles progress to a trailing update, and always emits the end", async () => {
    const clock = manualTimers()
    const { events, recorder, states } = recording(clock.timers)
    expect(events).toEqual([
      {
        kind: "session.output",
        subjectId: "session-1",
        payload: {
          kind: "codevisor_execution",
          argsHash: "hash-1",
          execution: { state: "running", calls: [] }
        }
      }
    ])

    recorder.status("Listing issues")
    recorder.call({ path: "linear.list_issues", ok: true, ms: 12 })
    clock.advance(EXECUTION_EMIT_INTERVAL_MS - 1)
    expect(states()).toHaveLength(1)
    clock.advance(1)
    expect(states().at(-1)).toEqual({
      state: "running",
      status: "Listing issues",
      calls: [{ path: "linear.list_issues", ok: true, ms: 12 }]
    })

    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    recorder.status("   ")
    expect(states().at(-1)).toEqual({
      state: "running",
      calls: [{ path: "linear.list_issues", ok: true, ms: 12 }]
    })

    recorder.call({ path: "xcode.build", machine: "MacBook", ok: false, ms: 3, error: "offline" })
    expect(clock.scheduledCount()).toBe(1)
    await recorder.finish("Script failed")
    expect(clock.scheduledCount()).toBe(0)
    expect(states().at(-1)).toEqual({
      state: "failed",
      calls: [
        { path: "linear.list_issues", ok: true, ms: 12 },
        { path: "xcode.build", machine: "MacBook", ok: false, ms: 3, error: "offline" }
      ],
      error: "Script failed"
    })

    const count = events.length
    recorder.call({ path: "late.call", ok: true, ms: 1 })
    await recorder.finish()
    expect(events).toHaveLength(count)
  })

  it("keeps the 50 most recent calls and bounds status and error text", async () => {
    const clock = manualTimers()
    const { recorder, states } = recording(clock.timers)
    for (let index = 0; index < 55; index += 1) {
      recorder.call({ path: `tool.call_${index}`, ok: true, ms: index })
    }
    recorder.call({ path: "tool.failed", ok: false, ms: 1, error: `bad ${"x".repeat(400)}` })
    recorder.status("s".repeat(300))
    await recorder.finish()

    expect(states().at(-1)).toMatchObject({
      state: "completed",
      status: `${"s".repeat(119)}…`,
      calls: [
        ...Array.from({ length: 49 }, (_, index) => ({ path: `tool.call_${index + 6}` })),
        { path: "tool.failed", error: `bad ${"x".repeat(195)}…` }
      ]
    })
  })

  it("never lets a failing or missing sink fail the execution", async () => {
    for (const sink of [
      async () => {
        throw new Error("sink closed")
      },
      () => {
        throw new Error("sink closed")
      }
    ]) {
      const failing = makeExecutionRecorder({ sink, sessionId: "session-1", argsHash: "hash-1" })
      failing.call({ path: "tool.one", ok: true, ms: 1 })
      await expect(failing.finish()).resolves.toBeUndefined()
    }

    const silent = makeExecutionRecorder({ sink: undefined, sessionId: "s", argsHash: "h" })
    silent.status("Working")
    await expect(silent.finish()).resolves.toBeUndefined()
  })

  it("reduces a thrown error to the message a person reads", () => {
    expect(
      errorSummary(
        "Error: codevisor.sessions.get does not accept `id`\n    at <anonymous> (codevisor-code-executor.js:45:187)",
        200
      )
    ).toBe("codevisor.sessions.get does not accept `id`")
    expect(
      errorSummary(
        "Error: Error: boom at <anonymous> (codevisor-code-executor.js:1:2) at toError (file:///x.js:1:1)",
        200
      )
    ).toBe("boom")
    expect(errorSummary("MachineUnavailableError: MacBook Pro is offline", 200)).toBe(
      "MacBook Pro is offline"
    )
    expect(errorSummary("Error:", 200)).toBe("Error:")
    expect(errorSummary("\n  \n", 200)).toBe("")
  })

  it("names a workflow by the first thing it touched, and shows what it touches now", async () => {
    const clock = manualTimers()
    const { recorder, states } = recording(clock.timers)
    const browser = { kind: "builtin", id: "browser" } as const
    const linear = { kind: "site", origin: "https://linear.app" } as const
    const sentry = { kind: "mcp", serverId: "sentry-id", host: "mcp.sentry.dev" } as const
    recorder.touch(browser)
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(states().at(-1)).toMatchObject({ icon: browser, activeIcon: browser })
    recorder.touch(linear)
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(states().at(-1)).toMatchObject({ icon: linear, activeIcon: linear })
    recorder.touch(sentry)
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(states().at(-1)).toMatchObject({ icon: linear, activeIcon: sentry })
    const emitted = states().length
    recorder.touch(sentry)
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(states()).toHaveLength(emitted)
    await recorder.finish()
    expect(states().at(-1)).toMatchObject({ state: "completed", icon: linear, activeIcon: sentry })
    recorder.touch(browser)
    expect(states().at(-1)).toMatchObject({ activeIcon: sentry })
  })

  it("names a desktop workflow by the app it drove", async () => {
    const clock = manualTimers()
    const { recorder, states } = recording(clock.timers)
    const computer = { kind: "builtin", id: "computer" } as const
    const music = appIcon({ bundleId: "com.apple.Music", name: "Music" })
    expect(music).toEqual({ kind: "app", bundleId: "com.apple.Music", name: "Music" })
    expect(appIcon({ bundleId: "a.b", path: "/Applications/B.app" })).toEqual({
      kind: "app",
      bundleId: "a.b",
      path: "/Applications/B.app"
    })
    recorder.touch(computer)
    recorder.touch(music)
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(states().at(-1)).toMatchObject({ icon: music, activeIcon: music })
    recorder.touch({ kind: "site", origin: "https://linear.app" })
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(states().at(-1)).toMatchObject({ icon: music })
    await recorder.finish()

    const browsing = recording(clock.timers)
    browsing.recorder.touch({ kind: "builtin", id: "browser" })
    browsing.recorder.touch(music)
    clock.advance(EXECUTION_EMIT_INTERVAL_MS)
    expect(browsing.states().at(-1)).toMatchObject({ icon: { kind: "builtin", id: "browser" } })
    await browsing.recorder.finish()
  })
})

describe("execution call icons", () => {
  it("maps sandbox paths to built-ins and MCP servers, skipping catalog lookups", async () => {
    const hosts: Record<string, string> = { "linear-id": "mcp.linear.app" }
    const serverHost = async (id: string) => {
      if (id === "gone") throw new Error("not found")
      return hosts[id]
    }
    expect(await executionCallIcon("search", serverHost)).toBeUndefined()
    expect(await executionCallIcon("describe.tool", serverHost)).toBeUndefined()
    expect(await executionCallIcon("browser.navigate", serverHost)).toEqual({
      kind: "builtin",
      id: "browser"
    })
    expect(await executionCallIcon("plugin.deploy", serverHost)).toEqual({
      kind: "builtin",
      id: "plugin"
    })
    expect(await executionCallIcon("linear-id.list_issues", serverHost)).toEqual({
      kind: "mcp",
      serverId: "linear-id",
      host: "mcp.linear.app"
    })
    expect(await executionCallIcon("gone.tool", serverHost)).toEqual({
      kind: "mcp",
      serverId: "gone"
    })
  })

  it("keeps only web origins as sites", () => {
    expect(siteIcon("https://linear.app/team/issue/ABC-1?x=1")).toEqual({
      kind: "site",
      origin: "https://linear.app"
    })
    expect(siteIcon("about:blank")).toBeUndefined()
    expect(siteIcon("not a url")).toBeUndefined()
  })
})

const files = (prefix: string, count: number) =>
  Array.from({ length: count }, (_, index) => ({ fileId: `${prefix}${index}` }))

describe("execution steps", () => {
  it("labels tools in words", () => {
    expect(humanizeToolName("search_models")).toBe("Search models")
    expect(humanizeToolName("resolve-library-id")).toBe("Resolve library id")
    expect(humanizeToolName("context.current")).toBe("Context current")
    expect(humanizeToolName("getIssue")).toBe("Get issue")
    expect(humanizeToolName("js")).toBe("Ran a script")
    expect(humanizeToolName("browser.js")).toBe("Used the browser")
    expect(humanizeToolName("computer.js")).toBe("Used the desktop")
    expect(humanizeToolName("__")).toBe("__")
  })

  it("finds the stored files a result references, once each", () => {
    const shot = { type: "artifact_ref", fileId: "f1", name: "shot.png", mediaType: "image/png" }
    expect(
      executionFiles({
        value: { title: "x" },
        artifacts: [shot, shot],
        file: { fileId: "f2", path: "/tmp/r.mp4", mimeType: "video/mp4" },
        nested: [[{ fileId: "f3" }]],
        count: 3
      })
    ).toEqual([
      { fileId: "f1", name: "shot.png", mimeType: "image/png" },
      { fileId: "f2", mimeType: "video/mp4" },
      { fileId: "f3" }
    ])
    expect(executionFiles("text")).toEqual([])
    expect(executionFiles({ a: { b: { c: { d: { e: { f: { fileId: "deep" } } } } } } })).toEqual([])
  })

  it("keeps a workflow's first files", async () => {
    const { recorder, states } = recording()
    recorder.call({ path: "browser.screenshot", ok: true, ms: 1, files: files("a", 10) })
    recorder.call({ path: "browser.screenshot", ok: true, ms: 1, files: files("b", 5) })
    recorder.call({ path: "browser.screenshot", ok: true, ms: 1, files: files("c", 1) })
    await recorder.finish()
    expect(states().at(-1)).toMatchObject({
      calls: [
        { files: files("a", 10) },
        { files: files("b", 2) },
        expect.not.objectContaining({ files: expect.anything() })
      ]
    })
  })
})
