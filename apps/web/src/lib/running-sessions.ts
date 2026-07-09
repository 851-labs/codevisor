// A tiny subscribable set of session ids that are currently generating,
// derived from the event stream (assistant output marks running; a stop
// reason or error clears it). Drives the sidebar's per-session spinner
// without loading every session's detail.
import type { EventEnvelope } from "@herdman/api"

import { sessionStreamEvents } from "./session-events"

type Listener = () => void

const running = new Set<string>()
const activeTurns = new Set<string>()
const waitingOnBackgroundTasks = new Set<string>()
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

function refreshRunning(sessionId: string): boolean {
  const shouldRun = activeTurns.has(sessionId) || waitingOnBackgroundTasks.has(sessionId)
  if (shouldRun && !running.has(sessionId)) {
    running.add(sessionId)
    return true
  }
  if (!shouldRun && running.delete(sessionId)) return true
  return false
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
      case "planDocumentUpdated":
        if (streamEvent.type === "textChunk" && streamEvent.role !== "assistant") break
        activeTurns.add(event.subjectId)
        if (refreshRunning(event.subjectId)) changed = true
        break
      case "backgroundTasksChanged":
        if (streamEvent.tasks.length > 0) {
          waitingOnBackgroundTasks.add(event.subjectId)
        } else {
          waitingOnBackgroundTasks.delete(event.subjectId)
        }
        if (refreshRunning(event.subjectId)) changed = true
        break
      case "finished":
      case "failed":
        activeTurns.delete(event.subjectId)
        if (refreshRunning(event.subjectId)) changed = true
        break
      default:
        break
    }
  }
  if (changed) notify()
}
