import type { EventEnvelope } from "@codevisor/api"

import { SHARED_ACCOUNTS_NAMESPACE } from "./infra/shared-account-store.js"
import type { RefreshScheduler } from "./routes/sync-readiness.js"
import {
  appendAndPublish,
  swallowError,
  type CodevisorServerServices,
  type EventFanout
} from "./server-context.js"

export const forwardSharedAccountEvents = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  authSyncRefresh: RefreshScheduler
): (() => void) => {
  const shared = services.sharedAccounts
  if (shared === undefined) return () => undefined

  const publish = (kind: EventEnvelope["kind"], subjectId: string, payload: unknown): void => {
    void appendAndPublish(services.db, fanout, kind, subjectId, payload).catch(swallowError)
  }
  const unsubscribes = [
    shared.subscribe((entries) => {
      publish("sync.changed", SHARED_ACCOUNTS_NAMESPACE, {
        namespace: SHARED_ACCOUNTS_NAMESPACE,
        entries
      })
      authSyncRefresh.request()
    }),
    shared.subscribeSelections((harnessId, activeAccountId) =>
      publish("harness.auth.updated", harnessId, { activeAccountId })
    ),
    shared.subscribeNotices((harnessId, notice) => publish("harness.notice", harnessId, notice))
  ]
  return () => {
    for (const unsubscribe of unsubscribes) unsubscribe()
  }
}
