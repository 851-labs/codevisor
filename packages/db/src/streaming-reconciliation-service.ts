import type { EventEnvelope } from "@codevisor/api"
import { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { makeEventsService } from "./events-service.js"
import { canonicalUuid } from "./ids.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import { makeTranscriptService } from "./transcript-service.js"

export type ReconcileQuietStreamingSession = (
  sessionId: string,
  quietSinceIso: string
) => Effect.Effect<
  { readonly repaired: number; readonly events: ReadonlyArray<EventEnvelope> },
  DatabaseError
>

// The quiet check, transcript lookup, question resolution, and terminal event
// are one synchronous transaction. A newer event invalidates the candidate;
// there is no await between validation and the destructive projection writes.
export const makeStreamingReconciliationService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "reconcileQuietStreamingSession"> => {
  const transcript = makeTranscriptService(context)
  const journal = makeEventsService(context)
  return {
    reconcileQuietStreamingSession: (rawId, quietSinceIso) =>
      attempt("reconcileQuietStreamingSession", () =>
        context.sqlite.transaction(() => {
          const id = canonicalUuid(rawId)
          const quiet = context.sqlite
            .prepare(
              "select 1 from sessions where id = ? and coalesce(last_event_at, created_at) <= ?"
            )
            .get(id, quietSinceIso)
          if (quiet === undefined) return { repaired: 0, events: [] }
          const page = Effect.runSync(transcript.getTranscriptPage(id, undefined, 1))
          const active = page.items.at(-1)
          const orphaned = active?.role === "assistant" && active.isGenerating
          const events: EventEnvelope[] = []
          const append = (kind: EventEnvelope["kind"], payload: unknown): void => {
            events.push(Effect.runSync(journal.appendEvent(kind, id, payload)))
          }
          let repaired = Effect.runSync(
            transcript.closeStaleAssistantChatItems(id, orphaned ? active.id : undefined)
          )
          if (orphaned) {
            if (page.pendingQuestion !== undefined) {
              append("session.output", {
                outcome: "cancelled",
                ...page.pendingQuestion,
                sessionUpdate: "question_resolved",
                serverId: context.config.serverId
              })
            }
            append("session.updated", {
              ...(active.turnId === undefined
                ? {}
                : { initiatedBy: "user", turnId: active.turnId, turnState: "ended" }),
              serverId: context.config.serverId,
              stopReason: "end_turn"
            })
            repaired += 1
          }
          if (repaired > 0) append("session.attention.updated", context.getSession(id))
          return { repaired, events }
        })()
      )
  }
}
