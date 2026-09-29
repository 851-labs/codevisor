import { isoTimestamp, type EventEnvelope } from "@codevisor/api"

import { attempt } from "./errors.js"
import { eventFromRow } from "./row-mappers.js"
import type { EventRow } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

/// Terminal panes' live titles and agent activity. The
/// navigation journal's pane trigger records each change, so clients receive
/// it as the same `navigation.changed` delta as any other pane edit.
/// `revision` is left alone: it orders client-driven pane conversions, and a
/// title settling must not make a client discard a snapshot that raced its own
/// conversion.
export const makeTerminalPaneTitlesService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "setTerminalPaneStatus" | "clearTerminalPaneStatuses"> => {
  const { sqlite } = context

  /// Runs `update` and returns the navigation changes its triggers journaled.
  const journaled = (update: (now: string) => void): ReadonlyArray<EventEnvelope> =>
    sqlite.transaction(() => {
      const { cursor } = sqlite
        .prepare("select coalesce(max(id), 0) as cursor from events")
        .get() as { readonly cursor: number }
      update(isoTimestamp())
      return (
        sqlite
          .prepare("select * from events where id > ? and kind = 'navigation.changed' order by id")
          .all(cursor) as ReadonlyArray<EventRow>
      ).map(eventFromRow)
    })()

  return {
    setTerminalPaneStatus: (terminalKey, liveTitle, activity) =>
      attempt("setTerminalPaneStatus", () =>
        journaled((now) => {
          // Pane resource ids are client-cased; terminal keys match them
          // case-insensitively everywhere else too.
          sqlite
            .prepare(
              `update workspace_panes set
                   live_title = @title,
                   terminal_activity = @activity,
                   updated_at = @now
                 where resource_kind = 'terminal' and lower(resource_id) = lower(@key)
                   and (live_title is not @title or terminal_activity is not @activity)`
            )
            .run({
              title: liveTitle ?? null,
              activity: activity ?? null,
              now,
              key: terminalKey
            })
        })
      ),
    clearTerminalPaneStatuses: attempt("clearTerminalPaneStatuses", () =>
      journaled((now) => {
        sqlite
          .prepare(
            `update workspace_panes set live_title = null, terminal_activity = null, updated_at = ?
               where live_title is not null or terminal_activity is not null`
          )
          .run(now)
      })
    )
  }
}
