import { PluginSetupRequest, PluginSetupState, type TranscriptPluginSetup } from "@codevisor/api"
import { Schema } from "effect"

import { payloadRows } from "./common-rows.js"
import { parseJsonRecord, type JsonRecord } from "./event-payloads.js"
import type { ServiceContext } from "./service-context.js"

export const itemPluginSetups = (
  sqlite: ServiceContext["sqlite"],
  itemId: string
): ReadonlyArray<TranscriptPluginSetup> =>
  payloadRows
    .all(sqlite.prepare(itemSetupEntriesSql).all(itemId))
    .flatMap((row) => pluginSetupOf(parseJsonRecord(row.payload)) ?? [])

export const pluginSetupOf = (
  payload: JsonRecord | undefined
): TranscriptPluginSetup | undefined => {
  const id = payload?.setupId
  const state = payload?.state
  const request = payload?.request
  if (typeof id !== "string" || !isSetupState(state) || !isSetupRequest(request)) return undefined
  return { id, state, request }
}

const isSetupState = Schema.is(PluginSetupState)

const isSetupRequest = Schema.is(PluginSetupRequest)

const itemSetupEntriesSql = `select payload from transcript_entries
  where item_id = ? and category = 'plugin_setup' order by position`
