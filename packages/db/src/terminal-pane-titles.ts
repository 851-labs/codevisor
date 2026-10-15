import { isoTimestamp, type EventEnvelope } from "@codevisor/api"

import { cursorRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import { eventFromRow } from "./row-mappers.js"
import { eventRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeTerminalPaneTitlesService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "setTerminalPaneStatus" | "clearTerminalPaneStatuses"> => {
  const { sqlite } = context

  const journaled = (update: (now: string) => void): ReadonlyArray<EventEnvelope> =>
    sqlite.transaction(() => {
      const { cursor } = cursorRows.one(
        sqlite.prepare("select coalesce(max(id), 0) as cursor from events").get()
      )
      update(isoTimestamp())
      return eventRows
        .all(
          sqlite
            .prepare(
              "select * from events where id > ? and kind = 'navigation.changed' order by id"
            )
            .all(cursor)
        )
        .map(eventFromRow)
    })()

  return {
    setTerminalPaneStatus: (terminalKey, liveTitle, activity) =>
      attempt("setTerminalPaneStatus", () =>
        journaled((now) => {
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
