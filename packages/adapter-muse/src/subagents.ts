import { subagentFinished } from "./agents.js"
import { makeMuseItemMapper, type MappedEvent, type MuseItemMapper } from "./items.js"
import { record, text, type MuseItem } from "./protocol.js"

/// A subagent's own work, nested under its row in the chat. Muse runs each
/// subagent as a child session it never streams on the parent's view (and
/// won't let a client subscribe to it), but it does serve the child's view
/// pages. So while a subagent runs, its pages are read on an interval and
/// its items mapped like the chat's own, attributed to the subagent's row.

/// The updates of a child session that belong in its thread; its prompt
/// echo, usage and lifecycle describe the child session itself.
const THREAD_UPDATES = new Set([
  "agent_message_chunk",
  "agent_thought_chunk",
  "tool_call",
  "tool_call_update"
])

export interface ViewPage {
  readonly events: ReadonlyArray<{ readonly method?: string; readonly params?: unknown }>
  readonly nextCursor?: string | null
}

export interface MuseSubagentsOptions {
  /// `view/page` for a child session, after `cursor` when given.
  readonly page: (sessionId: string, cursor: string | undefined) => Promise<ViewPage>
  readonly send: (event: MappedEvent) => void
  readonly intervalMs?: number
}

interface Child {
  /// The row its work nests under now: the spawn, or a later run's chip.
  parentToolCallId: string
  readonly mapper: MuseItemMapper
  /// Read so far. Kept when the subagent answers: a follow-up message runs
  /// it again in the same session, and reading resumes from here.
  cursor: string | undefined
  /// The subagent answered: one last read, then it stops being followed.
  settled: boolean
  /// Settled since the read in flight began: read once more after it.
  needsFinal: boolean
  reading: Promise<void> | undefined
}

export interface MuseSubagents {
  /// Every item the chat (or a followed child) reports: a subagent item
  /// starts, settles, or (messaged again) resumes following its session.
  /// `rowFor` names the row a subagent's work streams under now.
  readonly observe: (item: MuseItem, rowFor?: (itemId: string) => string) => void
  /// Reads every followed child to its end now; nothing to wait for when
  /// no subagent is being followed.
  readonly drain: () => Promise<void> | undefined
  readonly stop: () => void
}

export const makeMuseSubagents = (options: MuseSubagentsOptions): MuseSubagents => {
  /// Every child seen, followed or answered.
  const children = new Map<string, Child>()
  /// The children being read on the interval.
  const followed = new Set<string>()
  let timer: ReturnType<typeof setInterval> | undefined

  const attribute = (child: Child, mapped: ReadonlyArray<MappedEvent>) => {
    for (const event of mapped) {
      if (!THREAD_UPDATES.has(String(event.payload.sessionUpdate))) continue
      options.send({
        kind: event.kind,
        payload: { ...event.payload, parentToolCallId: child.parentToolCallId }
      })
    }
  }

  const apply = (child: Child, method: string | undefined, params: Record<string, unknown>) => {
    if (method === "item/started" || method === "item/updated" || method === "item/completed") {
      const item = record(params.item) as unknown as MuseItem
      if (typeof item.itemId !== "string") return
      attribute(child, child.mapper.item(item, method.slice("item/".length) as "started"))
      // A subagent's own subagents nest one level further down.
      observe(item, child.mapper.runRow)
    } else if (method === "item/delta" && typeof params.itemId === "string") {
      attribute(
        child,
        child.mapper.delta(params.itemId, text(params.field) ?? "text", String(params.delta ?? ""))
      )
    }
  }

  const read = (sessionId: string, child: Child): Promise<void> => {
    child.reading ??= (async () => {
      try {
        for (;;) {
          const page = await options.page(sessionId, child.cursor)
          for (const event of page.events) {
            const params = record(event.params)
            apply(child, event.method, params)
            child.cursor = text(params.viewCursor) ?? child.cursor
          }
          if (page.events.length > 0 && page.nextCursor) continue
          if (!child.needsFinal) break
          child.needsFinal = false
        }
      } catch {
        // A child Muse no longer serves (closed, pruned) has nothing more to show.
        child.settled = true
      } finally {
        child.reading = undefined
        if (child.settled) followed.delete(sessionId)
        if (followed.size === 0) stopTimer()
      }
    })()
    return child.reading
  }

  const stopTimer = () => {
    if (timer !== undefined) clearInterval(timer)
    timer = undefined
  }

  const tick = () => {
    for (const sessionId of followed) void read(sessionId, children.get(sessionId)!)
  }

  const observe = (item: MuseItem, rowFor: (itemId: string) => string = (itemId) => itemId) => {
    if (item.kind !== "subagent" || item.childSessionId === undefined) return
    const sessionId = item.childSessionId
    let child = children.get(sessionId)
    if (child === undefined) {
      child = {
        parentToolCallId: item.itemId,
        mapper: makeMuseItemMapper(() => sessionId),
        cursor: undefined,
        // First seen already answered (a quick subagent): read it once.
        settled: !subagentFinished(item),
        needsFinal: false,
        reading: undefined
      }
      children.set(sessionId, child)
    }
    child.parentToolCallId = rowFor(item.itemId)
    if (!subagentFinished(item)) {
      // Running: newly, or again after a follow-up message.
      if (!child.settled) return
      child.settled = false
      followed.add(sessionId)
      timer ??= setInterval(tick, options.intervalMs ?? 2000)
    } else if (!child.settled) {
      child.settled = true
      child.needsFinal = child.reading !== undefined
      void read(sessionId, child)
    }
  }

  return {
    observe,
    drain: () =>
      followed.size === 0
        ? undefined
        : Promise.all(
            [...followed].map((sessionId) => read(sessionId, children.get(sessionId)!))
          ).then(() => undefined),
    stop: () => {
      stopTimer()
      followed.clear()
      children.clear()
    }
  }
}
