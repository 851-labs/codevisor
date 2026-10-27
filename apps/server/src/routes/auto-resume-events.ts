import type { EventEnvelope } from "@codevisor/api"

import { isRecord } from "../unknown-values.js"

export type AutoResumeTrigger =
  | { readonly kind: "usageLimitStop"; readonly resetsAt: string | undefined }
  | { readonly kind: "turnStarted" }
  | { readonly kind: "turnFinished" }
  | { readonly kind: "sessionArchived" }
  | { readonly kind: "accountsChanged" }
  | { readonly kind: "signedIn"; readonly accountId: string }

export const autoResumeTrigger = (event: EventEnvelope): AutoResumeTrigger | undefined => {
  const payload = isRecord(event.payload) ? event.payload : {}
  if (event.kind === "harness.auth.updated") return { kind: "accountsChanged" }
  if (event.kind === "harness.authFlow.updated") return signedIn(payload)
  if (event.kind === "session.archived") return { kind: "sessionArchived" }
  if (event.kind !== "session.updated" && event.kind !== "session.error") return undefined

  if (payload.turnState === "started") return { kind: "turnStarted" }
  if (!endsTurn(event, payload)) return undefined
  if (payload.stopKind === "usageLimit") return usageLimitStop(payload)

  return { kind: "turnFinished" }
}

const endsTurn = (event: EventEnvelope, payload: Record<string, unknown>): boolean =>
  event.kind === "session.error" || payload.turnState === "ended"

const usageLimitStop = (payload: Record<string, unknown>): AutoResumeTrigger => ({
  kind: "usageLimitStop",
  resetsAt: typeof payload.resetsAt === "string" ? payload.resetsAt : undefined
})

const signedIn = (payload: Record<string, unknown>): AutoResumeTrigger | undefined => {
  if (payload.kind !== "complete" || typeof payload.accountId !== "string") return undefined
  return { kind: "signedIn", accountId: payload.accountId }
}
