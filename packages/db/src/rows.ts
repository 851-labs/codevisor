import type {
  AttachmentKind,
  EventKind,
  FileMetadata,
  HarnessAccount,
  HarnessAuthState,
  HarnessUpdateInfo,
  McpAuthType,
  McpConnectionState,
  McpServer,
  McpServerKind,
  McpTransport,
  NativeMcpRemoval,
  Project,
  SessionSidebarState,
  SessionSummary,
  UpdateInfo
} from "@codevisor/api"

export interface ProjectRow {
  readonly id: string
  readonly name: string
  readonly is_archived: number
  readonly archived_at: string | null
  readonly origin: Project["origin"]
  readonly created_at: string
  readonly repo_url: string | null
  readonly worktree_base_remote: string | null
  readonly worktree_base_branch: string | null
}

export interface ArchivedWorktreeRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly original_name: string
  readonly branch: string
  readonly parent_sha: string
  readonly snapshot_ref: string
  readonly created_at: string
}

export interface ProjectLocationRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly folder_path: string
  readonly created_at: string
}

export interface WorktreeRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly name: string
  readonly branch: string
  readonly created_at: string
}

export interface WorkspaceRow {
  readonly id: string
  readonly server_id: string
  readonly project_id: string
  readonly name: string
  readonly has_custom_name: number
  readonly root_directory: string | null
  readonly is_archived: number
  readonly archived_at: string | null
  readonly archive_cascade_from: string | null
  readonly created_at: string
  readonly updated_at: string | null
}

export interface WorkspacePaneRow {
  readonly id: string
  readonly workspace_id: string
  readonly provider_id: string
  readonly pane_type: string
  readonly title: string
  readonly resource_kind: string | null
  readonly resource_id: string | null
  readonly metadata: string | null
  readonly revision: number
  readonly created_at: string
  readonly updated_at: string | null
}

export interface SessionRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly harness_id: string
  readonly harness_account_id: string | null
  readonly agent_session_id: string | null
  readonly title: string
  readonly title_is_user_set: number
  readonly origin: SessionSummary["origin"]
  readonly is_archived: number
  readonly archived_at: string | null
  readonly archive_cascade_from: string | null
  readonly worktree_name: string | null
  readonly workspace_id: string | null
  readonly created_at: string
  readonly updated_at: string | null
  readonly sidebar_state: SessionSidebarState
  readonly sidebar_state_changed_at: string
  readonly usage_used: number | null
  readonly usage_size: number | null
  readonly input_tokens: number | null
  readonly cached_input_tokens: number | null
  readonly output_tokens: number | null
  readonly reasoning_output_tokens: number | null
  readonly total_tokens: number | null
  readonly cost_amount: number | null
  readonly cost_currency: string | null
  readonly cost_kind: "reported" | "estimated" | null
  readonly pending_question: string | null
  readonly background_tasks: string
  readonly config_selections: string
  readonly attention_latest_sequence: number
  readonly attention_last_seen_sequence: number
  readonly attention_unread_count: number
  readonly attention_has_unread_error: number
  readonly attention_manually_unread: number
  readonly pending_plan_approval: number
}

export interface HarnessAccountRow {
  readonly id: string
  readonly harness_id: string
  readonly profile_kind: HarnessAccount["profileKind"]
  readonly profile_key: string | null
  readonly label: string
  readonly email: string | null
  readonly organization_id: string | null
  readonly auth_method: string | null
  readonly auth_state: HarnessAuthState
  readonly can_login: number
  readonly can_logout: number
  readonly last_checked_at: string | null
  readonly detail: string | null
  readonly created_at: string
  readonly updated_at: string
  readonly removed_at: string | null
  readonly is_active: number
}

export interface McpServerRow {
  readonly id: string
  readonly name: string
  readonly kind: McpServerKind
  readonly transport: McpTransport
  readonly url: string | null
  readonly command: string | null
  readonly args: string
  readonly enabled: number
  readonly auth_type: McpAuthType
  readonly oauth_scope: string | null
  readonly connection_state: McpConnectionState
  readonly tool_count: number
  readonly detail: string | null
  readonly secret_cipher: string | null
  readonly created_at: string
  readonly updated_at: string
}

export interface McpServerRecord extends McpServer {
  readonly secretCipher?: string
}

/// One-time backup of a harness config file, taken before Codevisor's first
/// ever mutation of it and never overwritten afterwards.
export interface NativeConfigBackupRecord {
  readonly filePath: string
  readonly backupPath: string
  readonly createdAt: string
}

/// A parked native MCP removal; `fragment` is the verbatim parsed entry
/// (JSON-encoded) so restore can reinsert exactly what was removed.
export interface NativeMcpRemovalRecord extends NativeMcpRemoval {
  readonly fragment: string
}

export interface SaveNativeMcpRemovalRequest {
  readonly harnessId: string
  readonly configPath: string
  readonly serverName: string
  readonly fragment: string
}

export interface SaveMcpServerRecordRequest {
  readonly id?: string
  readonly name: string
  readonly kind?: McpServerKind
  readonly transport: McpTransport
  readonly url?: string
  readonly command?: string
  readonly args?: ReadonlyArray<string>
  readonly enabled: boolean
  readonly authType: McpAuthType
  readonly oauthScope?: string
  readonly connectionState: McpConnectionState
  readonly toolCount: number
  readonly detail?: string
  readonly secretCipher?: string
}

export interface HarnessAccountRecord extends HarnessAccount {
  readonly profileKey?: string
  readonly createdAt: string
  readonly updatedAt: string
}

export interface SaveHarnessAccountRequest {
  readonly id?: string
  readonly harnessId: string
  readonly profileKind: HarnessAccount["profileKind"]
  readonly profileKey?: string
  readonly label: string
  readonly email?: string
  readonly organizationId?: string
  readonly authMethod?: string
  readonly authState: HarnessAuthState
  readonly canLogin: boolean
  readonly canLogout: boolean
  readonly lastCheckedAt?: string
  readonly detail?: string
}

export interface UpdateHarnessAccountAuthRequest {
  readonly label?: string
  readonly email?: string | null
  readonly organizationId?: string | null
  readonly authMethod?: string | null
  readonly authState: HarnessAuthState
  readonly canLogin?: boolean
  readonly canLogout?: boolean
  readonly lastCheckedAt?: string
  readonly detail?: string | null
}

export interface ConversationRow {
  readonly id: string
  readonly role: "user" | "assistant" | "system"
  readonly message_id: string | null
  readonly text: string
  readonly created_at: string
  readonly is_generating: number
  readonly attachments: string | null
}

export interface EventRow {
  readonly id: number
  readonly server_id: string
  readonly kind: EventKind
  readonly subject_id: string
  readonly created_at: string
  readonly payload: string
  readonly transcript_item_id: string | null
}

export interface TranscriptRow {
  readonly id: string
  readonly session_id: string
  readonly sequence: number
  readonly role: "user" | "assistant"
  readonly text: string
  readonly created_at: string
  readonly updated_at: string
  readonly is_generating: number
  readonly has_details: number
  readonly turn_id: string | null
  readonly started_at: string | null
  readonly ended_at: string | null
  readonly stop_reason: string | null
  readonly stop_detail: string | null
  readonly retryable: number
  readonly plan_document: string | null
  readonly attachments: string | null
  readonly revision: number
}

export interface ChatItemRow {
  readonly id: string
  readonly session_id: string
  readonly position: number
  readonly role: "user" | "assistant" | "system" | "tool"
  readonly message_id: string | null
  readonly status: "streaming" | "complete" | "failed"
  readonly created_at: string
  readonly updated_at: string
  readonly turn_id: string | null
  readonly started_at: string | null
  readonly completed_at: string | null
  readonly stop_reason: string | null
  readonly stop_detail: string | null
  readonly retryable: number
  readonly attachments: string | null
  readonly has_details: number
  readonly revision: number
  /// Selected from the typed parts table by chat page queries.
  readonly text: string
  readonly plan_document: string | null
}

export interface SessionEventRow {
  readonly session_id: string
  readonly revision: number
  readonly global_event_id: number | null
  readonly server_id: string
  readonly kind: EventKind
  readonly created_at: string
  readonly payload: string
  readonly chat_item_id: string | null
}

export interface SessionActionRow {
  readonly session_id: string
  readonly client_action_id: string
  readonly action_kind: string
  readonly response: string
  readonly created_at: string
}

export interface PromptQueueRow {
  readonly id: string
  readonly session_id: string
  readonly text: string
  readonly created_at: string
  readonly updated_at: string
  readonly attachments: string | null
  readonly state: "pending" | "processing"
  readonly position: number
}

export interface FileRow {
  readonly id: string
  readonly name: string
  readonly mime_type: string
  readonly size_bytes: number
  readonly sha256: string
  readonly kind: AttachmentKind
  readonly created_at: string
  readonly storage_state: FileStorageState
}

export type FileStorageState = "sqlite" | "dual" | "disk"

export interface FileStorageRecord {
  readonly metadata: FileMetadata
  readonly storageState: FileStorageState
  /// Present for legacy/dual rows. Disk-only rows deliberately retain an empty
  /// BLOB sentinel until a later schema migration removes the column.
  readonly data: Buffer
}

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

export interface NativeConfigBackupRow {
  readonly file_path: string
  readonly backup_path: string
  readonly created_at: string
}

export interface NativeMcpRemovalRow {
  readonly id: string
  readonly harness_id: string
  readonly config_path: string
  readonly server_name: string
  readonly fragment: string
  readonly removed_at: string
  readonly restored_at: string | null
}
