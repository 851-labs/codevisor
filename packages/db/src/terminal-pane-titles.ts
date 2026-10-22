import { attempt } from "./errors.js"
import { journaledNavigationChanges } from "./navigation-changes.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

export const makeTerminalPaneTitlesService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "setTerminalPaneStatus" | "clearTerminalPaneStatuses"> => {
  const { sqlite } = context
  const journaled = journaledNavigationChanges(context)

  return {
    setTerminalPaneStatus: (terminalKey, liveTitle, activity) =>
      attempt("setTerminalPaneStatus", () =>
        journaled((now) => {
          sqlite.prepare(terminalStatusSql.set).run({
            title: liveTitle ?? null,
            activity: activity ?? null,
            now,
            key: terminalKey
          })
        })
      ),
    clearTerminalPaneStatuses: attempt("clearTerminalPaneStatuses", () =>
      journaled((now) => {
        sqlite.prepare(terminalStatusSql.clearAll).run(now)
      })
    )
  }
}

const terminalStatusSql = {
  set: `update workspace_panes set
                   live_title = @title,
                   terminal_activity = @activity,
                   updated_at = @now
                 where resource_kind = 'terminal' and lower(resource_id) = lower(@key)
                   and (live_title is not @title or terminal_activity is not @activity)`,
  clearAll: `update workspace_panes set live_title = null, terminal_activity = null, updated_at = ?
               where live_title is not null or terminal_activity is not null`
}
