import type { TranscriptPluginSetup } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { parseJsonRecord } from "./event-payloads.js"
import { pluginSetupOf } from "./item-plugin-setups.js"
import { rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export interface ShownPluginSetup extends TranscriptPluginSetup {
  readonly sessionId: string
}

export interface PluginSetupsService {
  readonly listPendingPluginSetups: Effect.Effect<ReadonlyArray<ShownPluginSetup>, DatabaseError>
}

export const makePluginSetupsService = (context: ServiceContext): PluginSetupsService => ({
  listPendingPluginSetups: attempt("listPendingPluginSetups", () =>
    shownSetupRows
      .all(context.sqlite.prepare(shownSetupsSql).all())
      .flatMap(shownSetup)
      .filter((setup) => setup.state === "pending")
  )
})

const shownSetup = (row: {
  readonly session_id: string
  readonly payload: string
}): ReadonlyArray<ShownPluginSetup> => {
  const setup = pluginSetupOf(parseJsonRecord(row.payload))
  return setup === undefined ? [] : [{ ...setup, sessionId: row.session_id }]
}

const shownSetupRows = rowReader({ session_id: text, payload: text })

const shownSetupsSql = `select item.session_id, entry.payload
  from transcript_entries entry
  join chat_items item on item.id = entry.item_id
  where entry.category = 'plugin_setup'`
