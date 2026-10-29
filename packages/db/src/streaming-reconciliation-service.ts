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
          if (!quietSince(context.sqlite, id, quietSinceIso)) return { repaired: 0, events: [] }
          const page = Effect.runSync(transcript.getTranscriptPage(id, undefined, 1))
          const active = page.items.at(-1)
          const agentQuestion =
            page.pendingQuestion === undefined || waitsOnPluginSetup(page.pendingQuestion)
              ? undefined
              : page.pendingQuestion
          const orphaned =
            active?.role === "assistant" && (active.isGenerating || agentQuestion !== undefined)
          const events: EventEnvelope[] = []
          const append = (kind: EventEnvelope["kind"], payload: unknown): void => {
            events.push(Effect.runSync(journal.appendEvent(kind, id, payload)))
          }
          let repaired = Effect.runSync(
            transcript.closeStaleAssistantChatItems(id, orphaned ? active.id : undefined)
          )
          if (orphaned) {
            if (agentQuestion !== undefined) {
              append("session.output", {
                outcome: "cancelled",
                ...agentQuestion,
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

const waitsOnPluginSetup = (question: {
  readonly questions: ReadonlyArray<{ readonly presentation?: string | undefined }>
}): boolean => question.questions.some((spec) => spec.presentation === "pluginSetup")

const quietSince = (sqlite: ServiceContext["sqlite"], id: string, quietSinceIso: string): boolean =>
  sqlite.prepare(quietSessionSql).get(id, quietSinceIso) !== undefined

const quietSessionSql =
  "select 1 from sessions where id = ? and coalesce(last_event_at, created_at) <= ?"
