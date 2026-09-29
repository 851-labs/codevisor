import type { EventEnvelope } from "@codevisor/api"
import type { CodevisorDatabaseService, DatabaseError } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { Effect } from "effect"

import { failureMessage, run, type EventFanout } from "../server-context.js"

/// Carries each terminal's settled title and activity onto the workspace panes
/// showing it, as their `liveTitle` and `terminalActivity`. The pane trigger
/// journals every change as `navigation.changed`; publishing those journaled
/// events wakes connected event readers without appending another event.
/// Returns a close that detaches and waits for the writes in flight.
export const forwardTerminalTitles = (
  db: CodevisorDatabaseService,
  terminal: TerminalManagerService,
  fanout: EventFanout
): (() => Promise<void>) => {
  // Writes run in order, so a quick title change cannot land before the one
  // it replaced.
  let writes = Promise.resolve()
  const write = (update: Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>): void => {
    writes = writes
      .then(async () => {
        for (const event of await run(update)) await run(fanout.publish(event))
      })
      // A title is cosmetic: a failed write must not stop later ones.
      .catch((cause: unknown) => {
        console.error(`Terminal title sync failed: ${failureMessage(cause)}`)
      })
  }
  // Every terminal from before this boot is gone (restored ones are closed
  // scrollback), so none of their titles or activity still applies.
  write(db.clearTerminalPaneStatuses)
  const unsubscribe = terminal.subscribeTitles((key, { title, activity }) =>
    write(db.setTerminalPaneStatus(key, title, activity))
  )
  return () => {
    unsubscribe()
    return writes
  }
}
