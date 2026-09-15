import type { EventEnvelope } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { WebSocket } from "ws"
import { run, type EventFanout } from "../server-context.js"

/**
 * Shell subscribers follow the durable log, not broadcast arrival order.
 * A broadcast only wakes the reader: sending it directly could advance past
 * an earlier attention update whose publisher was delayed. Periodic reads
 * also recover a lone update whose broadcast was lost entirely.
 */
export const attachShellEventSocket = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  since: number,
  socket: WebSocket,
  serverId: string,
  keepaliveMs: number
): Promise<void> => {
  let hasCursor = since < Number.MAX_SAFE_INTEGER
  let cursor = hasCursor ? since : 0
  let reading = false
  let dirty = false
  let closed = false

  const drain = async (): Promise<void> => {
    dirty = true
    if (reading || closed) return
    reading = true
    try {
      do {
        dirty = false
        if (hasCursor) {
          // Each read depends on the cursor produced by the previous read.
          // eslint-disable-next-line no-await-in-loop
          const events = await run(db.listEvents(cursor))
          for (const event of events) {
            if (closed) return
            // The predecessor describes this subscription's delivered log
            // position. Unlike id + 1, it tolerates holes from migrations.
            socket.send(JSON.stringify({ ...event, previousEventId: cursor }))
            cursor = event.id
          }
        }
      } while (dirty && !closed)
      if (closed) return
      socket.send(
        JSON.stringify({
          id: cursor,
          serverId,
          kind: "keepalive",
          subjectId: "",
          createdAt: new Date().toISOString(),
          payload: {}
        })
      )
    } catch {
      socket.close()
    } finally {
      reading = false
    }
  }

  const unsubscribe = fanout.subscribe((event: EventEnvelope) => {
    // Runtime chunks belong to per-chat streams, not the shell log.
    if (event.subjectRevision !== undefined && event.globalEventId === undefined) return
    const id = event.globalEventId ?? event.id
    if (!hasCursor) {
      // Preserve legacy live-only semantics: no history before the first
      // event, and a heartbeat must never opt a subscriber into history.
      cursor = id - 1
      hasCursor = true
    }
    if (id > cursor) void drain()
  })
  const timer = setInterval(() => void drain(), keepaliveMs)
  timer.unref()
  socket.on("close", () => {
    closed = true
    clearInterval(timer)
    unsubscribe()
  })
  await drain()
}
