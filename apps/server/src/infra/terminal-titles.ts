import type { EventEnvelope } from "@codevisor/api"
import type { CodevisorDatabaseService, DatabaseError } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { Effect } from "effect"

import { failureMessage, run, type EventFanout } from "../server-context.js"

export const forwardTerminalTitles = (
  db: CodevisorDatabaseService,
  terminal: TerminalManagerService,
  fanout: EventFanout
): (() => Promise<void>) => {
  let writes = Promise.resolve()
  const write = (update: Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>): void => {
    writes = writes
      .then(async () => {
        for (const event of await run(update)) await run(fanout.publish(event))
      })
      .catch((cause: unknown) => {
        console.error(`Terminal title sync failed: ${failureMessage(cause)}`)
      })
  }
  write(db.clearTerminalPaneStatuses)
  const unsubscribe = terminal.subscribeTitles((key, { title, activity }) =>
    write(db.setTerminalPaneStatus(key, title, activity))
  )
  return () => {
    unsubscribe()
    return writes
  }
}
