import { TranscriptPluginApp } from "@codevisor/api"
import { Schema } from "effect"

import { payloadRows } from "./common-rows.js"
import { jsonRecord, parseJsonRecord, type JsonRecord } from "./event-payloads.js"
import type { ServiceContext } from "./service-context.js"

const isPluginApp = Schema.is(TranscriptPluginApp)

export const itemPluginApps = (
  sqlite: ServiceContext["sqlite"],
  itemId: string
): ReadonlyArray<TranscriptPluginApp> => {
  const seen = new Set<string>()
  return payloadRows
    .all(sqlite.prepare(appToolEntriesSql).all(itemId))
    .flatMap((row) => completedApps(parseJsonRecord(row.payload)))
    .filter((app) => {
      if (seen.has(app.viewId)) return false
      seen.add(app.viewId)
      return true
    })
}

const completedApps = (payload: JsonRecord | undefined): ReadonlyArray<TranscriptPluginApp> => {
  const execution = jsonRecord(jsonRecord(payload?._meta)?.codevisorExecution)
  if (payload?.status !== "completed" || execution?.state === "failed") return []
  const apps = execution?.apps
  return Array.isArray(apps) ? apps.filter(isPluginApp) : []
}

const appToolEntriesSql = `select payload from transcript_entries
  where item_id = ? and category = 'tool' and payload like '%"codevisorExecution"%"apps"%'
  order by position`
