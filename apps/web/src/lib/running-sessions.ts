// A tiny subscribable set of session ids that are currently generating,
// derived from the event stream (assistant output marks running; a stop
// reason or error clears it). Drives the sidebar's per-session spinner
// without loading every session's detail.
import type { EventEnvelope } from "@herdman/api"

import { sessionStreamEvents } from "./session-events"

type Listener = () => void

const running = new Set<string>()
const listeners = new Set<Listener>()
let snapshot: ReadonlySet<string> = new Set()

function notify(): void {
  snapshot = new Set(running)
  for (const listener of listeners) listener()
}

export const runningSessionsStore = {
  subscribe(listener: Listener): () => void {
    listeners.add(listener)
    return () => {
      listeners.delete(listener)
    }
  },
  getSnapshot(): ReadonlySet<string> {
    return snapshot
  }
}

export function trackRunningSessions(event: EventEnvelope): void {
  let changed = false
  for (const streamEvent of sessionStreamEvents(event)) {
    switch (streamEvent.type) {
      case "textChunk":
      case "thoughtChunk":
      case "toolCall":
      case "toolCallUpdate":
      case "planUpdated":
        if (streamEvent.type === "textChunk" && streamEvent.role !== "assistant") break
        if (!running.has(event.subjectId)) {
          running.add(event.subjectId)
          changed = true
        }
        break
      case "finished":
      case "failed":
        if (running.delete(event.subjectId)) changed = true
        break
      default:
        break
    }
  }
  if (changed) notify()
}
