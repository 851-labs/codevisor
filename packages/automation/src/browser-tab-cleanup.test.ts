import { describe, expect, it } from "vitest"

import type { BrowserRuntime } from "./browser-cdp-engine.js"
import { finishSessionTabs, trackPopups, type SessionTargets } from "./browser-tab-cleanup.js"

const context = { projectId: "project", sessionId: "session" }

/// Only the parts these helpers touch: event subscription, the closed flag,
/// and the operation queue they serialize on.
const runtime = (closed = false) => {
  const handlers = new Map<string, (params: Readonly<Record<string, unknown>>) => void>()
  const active = {
    connection: {
      closed,
      on: (method: string, handler: (params: Readonly<Record<string, unknown>>) => void) => {
        handlers.set(method, handler)
        return () => handlers.delete(method)
      }
    },
    eventDisposers: [] as Array<() => void>,
    queue: Promise.resolve()
  } as unknown as BrowserRuntime
  const emit = (method: string, params: Readonly<Record<string, unknown>>) =>
    handlers.get(method)?.(params)
  return { active, emit }
}

describe("popup tracking", () => {
  it("adopts a page an agent's tab opened, and nothing else", () => {
    const { active, emit } = runtime()
    type Origin = "created" | "claimed"
    const sessionTargets: SessionTargets = new Map([
      ["managed:project:other", new Map<string, Origin>([["user-tab", "claimed"]])],
      ["managed:project:session", new Map<string, Origin>([["agent-tab", "created"]])],
      ["builtin:session:session", new Map<string, Origin>([["builtin-tab", "created"]])]
    ])
    trackPopups(sessionTargets, "managed:project", active)
    const created = (targetInfo: Record<string, unknown>) =>
      emit("Target.targetCreated", { targetInfo })

    created({ targetId: "popup", type: "page", openerId: "agent-tab" })
    created({ targetId: "worker", type: "service_worker", openerId: "agent-tab" })
    created({ targetId: "unrelated", type: "page" })
    created({ targetId: "foreign", type: "page", openerId: "builtin-tab" })
    created({ targetId: "agent-tab", type: "page", openerId: "agent-tab" })
    emit("Target.targetCreated", {})

    expect([...sessionTargets.get("managed:project:session")!]).toEqual([
      ["agent-tab", "created"],
      ["popup", "created"]
    ])
    expect(sessionTargets.get("managed:project:other")!.size).toBe(1)
    expect(sessionTargets.get("builtin:session:session")!.size).toBe(1)
    expect(active.eventDisposers).toHaveLength(1)
  })
})

describe("turn-end cleanup", () => {
  it("finalizes every backend the session used, past one that fails", async () => {
    const managed = runtime()
    const builtin = runtime()
    const sessionTargets: SessionTargets = new Map([
      ["builtin:session:session", new Map()],
      ["managed:project:session", new Map()],
      ["extension:session", new Map()]
    ])
    const runtimes = new Map([
      ["builtin:session", Promise.resolve(builtin.active)],
      ["managed:project", Promise.resolve(managed.active)],
      ["extension", Promise.reject(new Error("relay dropped"))]
    ])
    const finalized: string[] = []
    const failure = new Error("Browser disconnected")
    await expect(
      finishSessionTabs(
        context,
        sessionTargets,
        runtimes,
        async (_context, _active, _tool, args, backend) => {
          finalized.push(backend)
          expect(args).toEqual({ native: true })
          if (backend === "builtin") throw failure
          return { content: [] }
        }
      )
    ).rejects.toBe(failure)
    expect(finalized).toEqual(["builtin", "managed"])
  })

  it("skips backends with no tabs, no runtime, or a closed connection", async () => {
    const sessionTargets: SessionTargets = new Map([
      ["builtin:session:session", new Map()],
      ["managed:project:session", new Map()]
    ])
    const runtimes = new Map([["managed:project", Promise.resolve(runtime(true).active)]])
    let calls = 0
    await finishSessionTabs(context, sessionTargets, runtimes, async () => {
      calls += 1
      return { content: [] }
    })
    expect(calls).toBe(0)
  })
})
