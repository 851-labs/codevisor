import { setImmediate } from "node:timers/promises"

import type { CodevisorDatabaseService } from "@codevisor/db"
interface SyncEventSink {
  readonly bufferedAmount: number
  send(data: string): void
  close(code?: number, reason?: string): void
  on(event: "close", listener: () => void): unknown
}
import { run, type EventFanout } from "../server-context.js"

/** Notifications wake a bounded journal reader. No live-event array grows
 * behind replay or a slow network; slow consumers resnapshot durable state. */
export const attachSyncEventSocket = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  since: number,
  socket: SyncEventSink,
  serverId: string,
  subjectId?: string,
  keepaliveMs = 25_000
): Promise<void> => {
  let hasCursor = since < Number.MAX_SAFE_INTEGER
  let cursor = hasCursor ? since : 0
  let reading = false
  let dirty = false
  let closed = false
  const control = (kind: "keepalive" | "snapshot_required", revision: number): void => {
    socket.send(
      JSON.stringify({
        id: revision,
        serverId,
        kind,
        subjectId: subjectId ?? "",
        createdAt: new Date().toISOString(),
        payload: {}
      })
    )
  }
  const reset = (revision: number): void => {
    closed = true
    control("snapshot_required", revision)
    socket.close(1000, "snapshot required")
  }
  const drain = async (heartbeat = false): Promise<void> => {
    dirty = true
    if (reading || closed) return
    reading = true
    try {
      do {
        dirty = false
        if (socket.bufferedAmount > 1024 * 1024) {
          reset(cursor)
          return
        }
        if (hasCursor) {
          const batch = await run(db.readSyncBatch(cursor, subjectId))
          if (closed) return
          if (batch.requiresSnapshot) {
            reset(batch.cursor)
            return
          }
          for (const event of batch.events) {
            if (socket.bufferedAmount > 1024 * 1024) {
              reset(batch.cursor)
              return
            }
            const id =
              subjectId === undefined ? (event.globalEventId ?? event.id) : event.subjectRevision!
            socket.send(JSON.stringify({ ...event, id, previousEventId: cursor }))
            cursor = id
          }
        }
        if (dirty) await setImmediate()
      } while (dirty && !closed)
      if (!closed && heartbeat) control("keepalive", cursor)
    } catch {
      socket.close()
    } finally {
      reading = false
    }
  }
  const unsubscribe = fanout.subscribe((event) => {
    if (subjectId === undefined) {
      if (!hasCursor && event.globalEventId !== undefined) {
        cursor = event.globalEventId - 1
        hasCursor = true
      }
      void drain()
      return
    }
    if (event.subjectId !== subjectId) return
    const id = event.subjectRevision
    if (id === undefined) return
    if (!hasCursor) {
      cursor = id - 1
      hasCursor = true
    }
    if (id > cursor) void drain()
  })
  const timer = setInterval(() => void drain(true), keepaliveMs)
  timer.unref()
  socket.on("close", () => {
    closed = true
    clearInterval(timer)
    unsubscribe()
  })
  await drain(true)
}
