import { UpdateInfo, type HarnessUpdateInfo } from "@codevisor/api"
import { Schema } from "effect"

import { integer, nullable, rowReader, text } from "./row-reader.js"

export interface UpdateRow {
  readonly current_version: string
  readonly latest_version: string
  readonly update_available: number
  readonly channel: string
  readonly checked_at: string | null
  readonly migration_state: UpdateInfo["migrationState"]
}

export interface HarnessUpdateStateRecord {
  readonly harnessId: string
  readonly info: HarnessUpdateInfo
}

export interface HarnessUpdateStateRow {
  readonly harness_id: string
  readonly installed_version: string | null
  readonly latest_version: string | null
  readonly update_available: number
  readonly source: string | null
  readonly install_origin: string | null
  readonly channel: string | null
  readonly checked_at: string | null
}

export const updateRows = rowReader<UpdateRow>({
  current_version: text,
  latest_version: text,
  update_available: integer,
  channel: text,
  checked_at: nullable(text),
  migration_state: Schema.is(UpdateInfo.fields.migrationState)
})

export const harnessUpdateStateRows = rowReader<HarnessUpdateStateRow>({
  harness_id: text,
  installed_version: nullable(text),
  latest_version: nullable(text),
  update_available: integer,
  source: nullable(text),
  install_origin: nullable(text),
  channel: nullable(text),
  checked_at: nullable(text)
})
