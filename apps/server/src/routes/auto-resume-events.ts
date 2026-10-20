import type { EventEnvelope } from "@codevisor/api"

import { isRecord } from "../unknown-values.js"

export type AutoResumeTrigger =
  | { readonly kind: "usageLimitStop"; readonly resetsAt: string | undefined }
  | { readonly kind: "turnStarted" }
  | { readonly kind: "turnFinished" }
  | { readonly kind: "sessionArchived" }
  | { readonly kind: "accountActivated"; readonly accountId: string }

export const autoResumeTrigger = (event: EventEnvelope): AutoResumeTrigger | undefined => {
  const payload = isRecord(event.payload) ? event.payload : {}
  if (event.kind === "harness.auth.updated") return accountActivated(payload)
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

const accountActivated = (payload: Record<string, unknown>): AutoResumeTrigger | undefined => {
  if (typeof payload.activeAccountId !== "string") return undefined
  return { kind: "accountActivated", accountId: payload.activeAccountId }
}
