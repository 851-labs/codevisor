import { UpdateInfo, type HarnessUpdateInfo } from "@codevisor/api"
import { Schema } from "effect"

import { integer, literal, nullable, rowReader, text } from "./row-reader.js"

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

export interface HarnessPendingUpdateRecord {
  readonly harnessId: string
  readonly state: "pending" | "running"
  readonly targetVersion?: string
  readonly requestedAt: string
  readonly startedAt?: string
  readonly timeoutAt?: string
}

export interface HarnessPendingUpdateRow {
  readonly harness_id: string
  readonly state: "pending" | "running"
  readonly target_version: string | null
  readonly requested_at: string
  readonly started_at: string | null
  readonly timeout_at: string | null
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

export const harnessPendingUpdateRows = rowReader<HarnessPendingUpdateRow>({
  harness_id: text,
  state: literal("pending", "running"),
  target_version: nullable(text),
  requested_at: text,
  started_at: nullable(text),
  timeout_at: nullable(text)
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
