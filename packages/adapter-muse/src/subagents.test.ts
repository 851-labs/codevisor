import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import type { MappedEvent } from "./items.js"
import type { MuseItem } from "./protocol.js"
import { makeMuseSubagents, type ViewPage } from "./subagents.js"

const CHILD = "child-1"

// The subagent row in the chat, as Muse 1.4.7 reports it.
const agent = (fields: Partial<MuseItem> = {}): MuseItem => ({
  itemId: "agent-1",
  kind: "subagent",
  revision: 2,
  status: "inProgress",
  controlStatus: "running",
  childSessionId: CHILD,
  ...fields
})

// One event of the child session's view, as `view/page` serves it.
const event = (cursor: number, method: string, params: Record<string, unknown> = {}) => ({
  method,
  params: { sessionId: CHILD, viewCursor: `v:${CHILD}:${cursor}`, ...params }
})
const read = (cursor: number, status: string, itemId = "r1") =>
  event(cursor, status === "inProgress" ? "item/started" : "item/completed", {
    item: {
      itemId,
      kind: "toolCall",
      revision: status === "inProgress" ? 1 : 2,
      status,
      tool: "read_file",
      args: '{"path":"calc.py"}'
    }
  })

/// A child session whose view grows as the test appends to it.
const setup = (intervalMs = 1000) => {
  const views = new Map<string, Array<ReturnType<typeof event>>>()
  const calls: Array<{ sessionId: string; cursor: string | undefined }> = []
  const sent: Array<MappedEvent> = []
  let failure: Error | undefined
  let gate: Promise<void> | undefined
  const page = async (sessionId: string, cursor: string | undefined): Promise<ViewPage> => {
    calls.push({ sessionId, cursor })
    const all = views.get(sessionId) ?? []
    await gate
    if (failure) throw failure
    const start =
      cursor === undefined ? 0 : all.findIndex((entry) => entry.params.viewCursor === cursor) + 1
    // Two events a page, so longer views take several.
    const events = all.slice(start, start + 2)
    return {
      events,
      nextCursor: start + 2 < all.length ? String(events.at(-1)?.params.viewCursor) : null
    }
  }
  const subagents = makeMuseSubagents({
    page,
    send: (mapped) => sent.push(mapped),
    intervalMs
  })
  return {
    subagents,
    calls,
    sent,
    append: (sessionId: string, ...added: Array<ReturnType<typeof event>>) =>
      views.set(sessionId, [...(views.get(sessionId) ?? []), ...added]),
    fail: (error: Error) => {
      failure = error
    },
    hold: () => {
      let release!: () => void
      gate = new Promise((resolve) => {
        release = resolve
      })
      return () => {
        gate = undefined
        release()
      }
    },
    threads: () =>
      sent.map((mapped) => [
        mapped.payload.sessionUpdate,
        mapped.payload.parentToolCallId,
        mapped.payload.status
      ])
  }
}

beforeEach(() => {
  vi.useFakeTimers()
})
afterEach(() => {
  vi.useRealTimers()
})

describe("Muse subagents", () => {
  it("streams a running subagent's own work into its row, page by page", async () => {
    const f = setup()
    f.append(
      CHILD,
      event(1, "turn/started"),
      event(2, "item/completed", {
        item: {
          itemId: "u",
          kind: "userMessage",
          revision: 1,
          status: "completed",
          text: "Role: reviewer"
        }
      }),
      read(3, "inProgress")
    )
    f.subagents.observe(agent())
    f.subagents.observe(agent({ revision: 3 }))
    await vi.advanceTimersByTimeAsync(1000)
    // The prompt echo and lifecycle stay out of the thread; its work nests under the row.
    expect(f.threads()).toEqual([["tool_call", "agent-1", "in_progress"]])
    expect(f.calls).toEqual([
      { sessionId: CHILD, cursor: undefined },
      { sessionId: CHILD, cursor: `v:${CHILD}:2` }
    ])

    f.append(
      CHILD,
      event(4, "item/delta", { itemId: "m1", delta: "No bugs" }),
      event(5, "session/tokenUsage"),
      read(6, "completed")
    )
    await vi.advanceTimersByTimeAsync(1000)
    expect(f.threads().slice(1)).toEqual([
      ["agent_message_chunk", "agent-1", undefined],
      ["tool_call_update", "agent-1", "completed"]
    ])
    // A compaction is the child session's own; an event without a cursor keeps the last one.
    f.append(
      CHILD,
      event(7, "item/started", {
        item: {
          itemId: "c",
          kind: "compaction",
          revision: 1,
          status: "inProgress"
        }
      }),
      {
        method: "session/statusChanged",
        params: { sessionId: CHILD }
      } as unknown as ReturnType<typeof event>
    )
    await vi.advanceTimersByTimeAsync(1000)
    expect(f.sent).toHaveLength(3)
    // Nothing new: nothing sent.
    await vi.advanceTimersByTimeAsync(1000)
    expect(f.sent).toHaveLength(3)
  })

  it("reads once more when the subagent answers, then stops following it", async () => {
    const f = setup()
    f.subagents.observe(agent())
    f.append(CHILD, read(1, "inProgress"))
    f.subagents.observe(agent({ revision: 3, controlStatus: "resultReady" }))
    expect(f.calls).toEqual([{ sessionId: CHILD, cursor: undefined }])
    await f.subagents.drain()
    expect(f.threads()).toEqual([["tool_call", "agent-1", "in_progress"]])
    const calls = f.calls.length
    // Muse restating the answer reads nothing more.
    f.subagents.observe(agent({ revision: 4, controlStatus: "resultReady" }))
    await vi.advanceTimersByTimeAsync(5000)
    expect(f.calls).toHaveLength(calls)
    expect(f.subagents.drain()).toBeUndefined()
  })

  it("catches up on work that lands while a read is already in flight", async () => {
    const f = setup()
    f.subagents.observe(agent())
    const release = f.hold()
    await vi.advanceTimersByTimeAsync(1000)
    // The subagent answers while the tick's read waits on Muse.
    f.append(CHILD, read(1, "inProgress"), read(2, "completed"))
    f.subagents.observe(agent({ revision: 3, controlStatus: "closed" }))
    const drained = f.subagents.drain()
    release()
    await drained
    expect(f.threads()).toEqual([
      ["tool_call", "agent-1", "in_progress"],
      ["tool_call_update", "agent-1", "completed"]
    ])
  })

  it("follows a subagent again when a message runs it, from where it left off, under that run's row", async () => {
    const f = setup()
    f.subagents.observe(agent())
    f.append(CHILD, read(1, "inProgress"), read(2, "completed"))
    f.subagents.observe(agent({ revision: 3, controlStatus: "resultReady" }))
    expect(f.calls).toEqual([{ sessionId: CHILD, cursor: undefined }])
    await f.subagents.drain()
    // A later turn messages it: Muse runs it again in the same child session,
    // and the chat gives that run a chip of its own.
    f.subagents.observe(agent({ revision: 4 }), () => "agent-1:2")
    // Another subagent starting meanwhile shares the same interval.
    f.subagents.observe(agent({ itemId: "agent-2", childSessionId: "child-2" }))
    f.append(CHILD, read(3, "inProgress", "r2"))
    const calls = f.calls.length
    await vi.advanceTimersByTimeAsync(1000)
    expect(f.calls.slice(calls)).toEqual([
      { sessionId: CHILD, cursor: `v:${CHILD}:2` },
      { sessionId: "child-2", cursor: undefined }
    ])
    expect(f.threads().slice(-1)).toEqual([["tool_call", "agent-1:2", "in_progress"]])
  })

  it("nests a subagent's own subagents one level further down", async () => {
    const f = setup()
    f.subagents.observe(agent())
    f.append(
      CHILD,
      event(1, "item/started", {
        item: {
          itemId: "agent-2",
          kind: "subagent",
          revision: 1,
          status: "inProgress",
          role: "tester",
          subagentId: "subagent-1"
        }
      })
    )
    f.append(
      CHILD,
      event(2, "item/updated", {
        item: {
          itemId: "agent-2",
          kind: "subagent",
          revision: 2,
          status: "inProgress",
          childSessionId: "grandchild"
        }
      })
    )
    f.append(
      "grandchild",
      event(1, "item/started", {
        item: {
          itemId: "g1",
          kind: "toolCall",
          revision: 1,
          status: "inProgress",
          tool: "bash",
          args: "{}"
        }
      })
    )
    await vi.advanceTimersByTimeAsync(1000)
    await vi.advanceTimersByTimeAsync(1000)
    expect(f.threads()).toEqual([
      ["tool_call", "agent-1", "in_progress"],
      ["tool_call", "agent-2", "in_progress"]
    ])
    // Its id is scoped to the child session it was spawned in.
    expect(f.sent[0]!.payload._meta).toEqual({
      codevisorSubagent: { taskId: `${CHILD}:subagent-1` }
    })
  })

  it("drains every followed child before the turn ends, and gives up on one Muse no longer serves", async () => {
    const f = setup()
    expect(f.subagents.drain()).toBeUndefined()
    f.subagents.observe({ ...agent(), kind: "toolCall" })
    const { childSessionId: _child, ...unstarted } = agent()
    f.subagents.observe(unstarted)
    expect(f.subagents.drain()).toBeUndefined()

    f.subagents.observe(agent())
    f.append(
      CHILD,
      read(1, "inProgress"),
      event(2, "item/updated", { item: {} }),
      event(3, "item/delta", { itemId: "r1", field: "output", delta: "x" }),
      event(4, "item/delta", { itemId: "r1", field: "output" })
    )
    await f.subagents.drain()
    expect(f.threads()).toEqual([
      ["tool_call", "agent-1", "in_progress"],
      ["tool_call_update", "agent-1", undefined]
    ])
    f.fail(new Error("sessionNotFound"))
    await f.subagents.drain()
    expect(f.subagents.drain()).toBeUndefined()
  })

  it("stops following everything when the chat closes", async () => {
    const f = setup(500)
    f.subagents.observe(agent())
    f.subagents.stop()
    await vi.advanceTimersByTimeAsync(2000)
    expect(f.calls).toEqual([])
    // The default interval follows a child too.
    const slow = makeMuseSubagents({
      page: async () => ({ events: [] }),
      send: () => undefined
    })
    slow.observe(agent())
    slow.stop()
  })
})
