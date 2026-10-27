import { isoTimestamp } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { parseJsonObject } from "./json-column.js"
import { integer, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface PluginAppContextUpdate {
  readonly sessionId: string
  readonly viewId: string
  readonly plugin: string
  readonly tool: string
  readonly context: Readonly<Record<string, unknown>>
}

export interface PluginAppContextRecord extends PluginAppContextUpdate {
  readonly revision: number
  readonly updatedAt: string
}

export interface DeliveredPluginAppContext {
  readonly viewId: string
  readonly revision: number
}

export interface PluginAppContextsService {
  readonly savePluginAppContext: (
    update: PluginAppContextUpdate
  ) => Effect.Effect<void, DatabaseError>
  readonly listPluginAppContexts: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PluginAppContextRecord>, DatabaseError>
  readonly clearPluginAppContexts: (
    sessionId: string,
    delivered: ReadonlyArray<DeliveredPluginAppContext>
  ) => Effect.Effect<void, DatabaseError>
}

export const makePluginAppContextsService = (context: ServiceContext): PluginAppContextsService => {
  const { sqlite, getSession } = context

  return {
    savePluginAppContext: (update) =>
      attempt("savePluginAppContext", () => {
        const sessionId = canonicalUuid(update.sessionId)
        getSession(sessionId)
        sqlite
          .prepare(appContextSql.upsert)
          .run(
            sessionId,
            update.viewId,
            update.plugin,
            update.tool,
            JSON.stringify(update.context),
            isoTimestamp()
          )
      }),
    listPluginAppContexts: (sessionId) =>
      attempt("listPluginAppContexts", () =>
        appContextRows
          .all(sqlite.prepare(appContextSql.bySession).all(canonicalUuid(sessionId)))
          .map(appContextFromRow)
      ),
    clearPluginAppContexts: (sessionId, delivered) =>
      attempt("clearPluginAppContexts", () => {
        const clear = sqlite.prepare(appContextSql.clear)
        for (const { viewId, revision } of delivered) {
          clear.run(canonicalUuid(sessionId), viewId, revision)
        }
      })
  }
}

interface AppContextRow {
  readonly session_id: string
  readonly view_id: string
  readonly plugin: string
  readonly tool: string
  readonly context: string
  readonly revision: number
  readonly updated_at: string
}

const appContextRows = rowReader<AppContextRow>({
  session_id: text,
  view_id: text,
  plugin: text,
  tool: text,
  context: text,
  revision: integer,
  updated_at: text
})

const appContextFromRow = (row: AppContextRow): PluginAppContextRecord => ({
  sessionId: row.session_id,
  viewId: row.view_id,
  plugin: row.plugin,
  tool: row.tool,
  context: parseJsonObject(row.context),
  revision: row.revision,
  updatedAt: row.updated_at
})

const appContextSql = {
  upsert: `insert into plugin_app_contexts
    (session_id, view_id, plugin, tool, context, revision, updated_at)
    values (?, ?, ?, ?, ?, 1, ?)
    on conflict(session_id, view_id) do update set
      plugin = excluded.plugin,
      tool = excluded.tool,
      context = excluded.context,
      revision = plugin_app_contexts.revision + 1,
      updated_at = excluded.updated_at
    where plugin_app_contexts.context != excluded.context`,
  bySession: "select * from plugin_app_contexts where session_id = ? order by rowid",
  clear: "delete from plugin_app_contexts where session_id = ? and view_id = ? and revision = ?"
}
