import type { HarnessUpdateInfo, UpdateInfo } from "@codevisor/api"

export interface UpdateRow {
  readonly current_version: string
  readonly latest_version: string
  readonly update_available: number
  readonly channel: string
  readonly checked_at: string | null
  readonly migration_state: UpdateInfo["migrationState"]
}

/// One harness's persisted latest-version knowledge (see migration 23).
export interface HarnessUpdateStateRecord {
  readonly harnessId: string
  readonly info: HarnessUpdateInfo
}

/// A user-armed update waiting for the harness's chats to settle, or one
/// currently executing (see migration 24). Durable so a server restart can
/// reconcile interrupted updates instead of leaving prompts gated.
export interface HarnessPendingUpdateRecord {
  readonly harnessId: string
  readonly state: "pending" | "running"
  readonly targetVersion?: string
  readonly requestedAt: string
  readonly startedAt?: string
  /// Force-release deadline while running; startup reconcile clears rows
  /// past it.
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
