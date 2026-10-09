import { dirname } from "node:path"

import { repoIdentityKey } from "@codevisor/api"
import type {
  ArchivedWorktree,
  FileMetadata,
  Project,
  ProjectLocation,
  SessionSummary,
  UpdateInfo,
  Workspace,
  WorkspacePane,
  Worktree
} from "@codevisor/api"

import { sessionConfigSelectionsFromRaw } from "./event-payloads.js"
import { scratchWorkspacesRoot } from "./paths.js"
import { resolveSessionCwd, worktreePath } from "./paths.js"
import type {
  ArchivedWorktreeRow,
  FileRow,
  FileStorageRecord,
  HarnessAccountRecord,
  HarnessAccountRow,
  HarnessPendingUpdateRecord,
  HarnessPendingUpdateRow,
  HarnessUpdateStateRecord,
  HarnessUpdateStateRow,
  McpServerRecord,
  McpServerRow,
  NativeMcpRemovalRecord,
  NativeMcpRemovalRow,
  ProjectLocationRow,
  ProjectRow,
  SessionRow,
  UpdateRow,
  WorkspaceRow,
  WorkspacePaneRow,
  WorktreeRow
} from "./rows.js"

export {
  serializeAttachments,
  parseAttachments,
  transcriptFromChatRow,
  promptQueueFromRow,
  listPromptQueueSync,
  eventFromRow,
  sessionEventFromRow
} from "./message-row-codecs.js"

const projectLocationFromRow = (row: ProjectLocationRow): ProjectLocation => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  folderPath: row.folder_path,
  ...(row.is_git_repository == null ? {} : { isGitRepository: row.is_git_repository === 1 }),
  createdAt: row.created_at
})

export const projectFromRow = (
  row: ProjectRow,
  locations: ReadonlyArray<ProjectLocationRow>
): Project => ({
  id: row.id,
  name: row.name,
  origin: row.origin,
  createdAt: row.created_at,
  locations: locations.map(projectLocationFromRow),
  ...(locations.some((location) => dirname(location.folder_path) === scratchWorkspacesRoot())
    ? { isScratch: true }
    : {}),
  ...(row.repo_url === null ? {} : { repoKey: repoIdentityKey(row.repo_url) }),
  ...(row.repo_url === null ? {} : { repoUrl: row.repo_url }),
  ...(row.worktree_base_remote === null || row.worktree_base_branch === null
    ? {}
    : {
        worktreeBase: {
          remote: row.worktree_base_remote,
          branch: row.worktree_base_branch
        }
      }),
  ...(row.default_run_location === "projectDirectory" || row.default_run_location === "newWorktree"
    ? { defaultRunLocation: row.default_run_location }
    : {})
})

export const archivedWorktreeFromRow = (row: ArchivedWorktreeRow): ArchivedWorktree => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  originalName: row.original_name,
  branch: row.branch,
  parentSha: row.parent_sha,
  snapshotRef: row.snapshot_ref,
  createdAt: row.created_at,
  state: row.state
})

export const worktreeFromRow = (row: WorktreeRow): Worktree => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  name: row.name,
  branch: row.branch,
  path: worktreePath(row.project_id, row.name),
  createdAt: row.created_at
})

/// Labels are stored as a JSON object of strings. An empty or unreadable
/// value reads as no labels so a hand-edited row can never fail a listing.
export const parseLabels = (
  raw: string | null | undefined
): Readonly<Record<string, string>> | undefined => {
  if (raw == null) return undefined
  try {
    const parsed = JSON.parse(raw) as unknown
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return undefined
    const entries = Object.entries(parsed).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string"
    )
    return entries.length === 0 ? undefined : Object.fromEntries(entries)
  } catch {
    return undefined
  }
}

/// The stored form of a labels write: an empty object clears them.
export const serializeLabels = (
  labels: Readonly<Record<string, string>> | undefined
): string | null =>
  labels === undefined || Object.keys(labels).length === 0 ? null : JSON.stringify(labels)

export const workspaceFromRow = (row: WorkspaceRow): Workspace => {
  const labels = parseLabels(row.labels)
  return {
    sidebarPosition: row.sidebar_position,
    sidebarOrderRevision: row.sidebar_order_revision,
    id: row.id,
    serverId: row.server_id,
    projectId: row.project_id,
    name: row.name,
    hasCustomName: row.has_custom_name === 1,
    ...(row.root_directory === null ? {} : { rootDirectory: row.root_directory }),
    isArchived: row.is_archived === 1,
    ...(row.archived_at === null ? {} : { archivedAt: row.archived_at }),
    createdAt: row.created_at,
    ...(row.updated_at === null ? {} : { updatedAt: row.updated_at }),
    ...(labels === undefined ? {} : { labels })
  }
}

export const workspacePaneFromRow = (row: WorkspacePaneRow): WorkspacePane => ({
  id: row.id,
  workspaceId: row.workspace_id,
  providerId: row.provider_id,
  paneType: row.pane_type,
  title: row.title,
  ...(row.resource_kind === null ? {} : { resourceKind: row.resource_kind }),
  ...(row.resource_id === null ? {} : { resourceId: row.resource_id }),
  ...(row.metadata === null ? {} : { metadata: row.metadata }),
  ...(row.live_title === null ? {} : { liveTitle: row.live_title }),
  ...(row.terminal_activity === null ? {} : { terminalActivity: row.terminal_activity }),
  revision: row.revision,
  ...(row.position === "" ? {} : { position: row.position }),
  createdAt: row.created_at,
  ...(row.updated_at === null ? {} : { updatedAt: row.updated_at })
})

export const sessionFromRow = (row: SessionRow, folderPath: string | undefined): SessionSummary => {
  const cwd = resolveSessionCwd(folderPath, row.project_id, row.worktree_name ?? undefined)
  const configSelections = sessionConfigSelectionsFromRaw(row.config_selections)
  const unavailableConfigSelections = sessionConfigSelectionsFromRaw(
    row.unavailable_config_selections
  )
  const labels = parseLabels(row.labels)
  return {
    id: row.id,
    projectId: row.project_id,
    serverId: row.server_id,
    harnessId: row.harness_id,
    ...(row.harness_account_id === null ? {} : { harnessAccountId: row.harness_account_id }),
    ...(row.agent_session_id === null ? {} : { agentSessionId: row.agent_session_id }),
    title: row.title,
    origin: row.origin,
    ...(row.worktree_name === null ? {} : { worktreeName: row.worktree_name }),
    ...(row.workspace_id === null ? {} : { workspaceId: row.workspace_id }),
    ...(cwd === undefined ? {} : { cwd }),
    ...(Object.keys(configSelections).length === 0 ? {} : { configSelections }),
    ...(Object.keys(unavailableConfigSelections).length === 0
      ? {}
      : { unavailableConfigSelections }),
    createdAt: row.created_at,
    ...(row.updated_at === null ? {} : { updatedAt: row.updated_at }),
    sidebarState: row.sidebar_state,
    sidebarStateChangedAt: row.sidebar_state_changed_at,
    latestAttentionSequence: row.attention_latest_sequence,
    lastSeenAttentionSequence: row.attention_last_seen_sequence,
    unreadCount: row.attention_unread_count,
    hasUnreadError: row.attention_has_unread_error === 1,
    actionRequired: row.pending_question !== null || row.pending_plan_approval === 1,
    ...(row.pending_question !== null
      ? { actionRequiredKind: "question" as const }
      : row.pending_plan_approval === 1
        ? { actionRequiredKind: "planApproval" as const }
        : {}),
    pendingPlanApproval: row.pending_plan_approval === 1,
    ...(row.parent_session_id == null ? {} : { parentSessionId: row.parent_session_id }),
    ...(labels === undefined ? {} : { labels }),
    usage: {
      ...(row.usage_used === null ? {} : { used: row.usage_used }),
      ...(row.usage_size === null ? {} : { size: row.usage_size }),
      ...(row.input_tokens === null ? {} : { inputTokens: row.input_tokens }),
      ...(row.cached_input_tokens === null ? {} : { cachedInputTokens: row.cached_input_tokens }),
      ...(row.output_tokens === null ? {} : { outputTokens: row.output_tokens }),
      ...(row.reasoning_output_tokens === null
        ? {}
        : { reasoningOutputTokens: row.reasoning_output_tokens }),
      ...(row.total_tokens === null ? {} : { totalTokens: row.total_tokens }),
      ...(row.cost_amount === null ? {} : { costAmount: row.cost_amount }),
      ...(row.cost_currency === null ? {} : { costCurrency: row.cost_currency }),
      ...(row.cost_kind === null ? {} : { costKind: row.cost_kind })
    }
  }
}

export const harnessAccountFromRow = (row: HarnessAccountRow): HarnessAccountRecord => ({
  id: row.id,
  harnessId: row.harness_id,
  profileKind: row.profile_kind,
  ...(row.profile_key === null ? {} : { profileKey: row.profile_key }),
  label: row.label,
  ...(row.email === null ? {} : { email: row.email }),
  ...(row.organization_id === null ? {} : { organizationId: row.organization_id }),
  ...(row.auth_method === null ? {} : { authMethod: row.auth_method }),
  authState: row.auth_state,
  isActive: row.is_active === 1,
  canLogin: row.can_login === 1,
  canLogout: row.can_logout === 1,
  ...(row.last_checked_at === null ? {} : { lastCheckedAt: row.last_checked_at }),
  ...(row.detail === null ? {} : { detail: row.detail }),
  createdAt: row.created_at,
  updatedAt: row.updated_at
})

export const fileMetadataFromRow = (row: FileRow): FileMetadata => ({
  id: row.id,
  name: row.name,
  mimeType: row.mime_type,
  sizeBytes: row.size_bytes,
  sha256: row.sha256,
  kind: row.kind,
  createdAt: row.created_at
})

export const fileStorageRecordFromRow = (
  row: FileRow & { readonly data: Buffer }
): FileStorageRecord => ({
  metadata: fileMetadataFromRow(row),
  storageState: row.storage_state,
  data: row.data
})

export const harnessPendingUpdateFromRow = (
  row: HarnessPendingUpdateRow
): HarnessPendingUpdateRecord => ({
  harnessId: row.harness_id,
  requestedAt: row.requested_at,
  state: row.state,
  ...(row.target_version === null ? {} : { targetVersion: row.target_version }),
  ...(row.started_at === null ? {} : { startedAt: row.started_at }),
  ...(row.timeout_at === null ? {} : { timeoutAt: row.timeout_at })
})

export const harnessUpdateStateFromRow = (
  row: HarnessUpdateStateRow
): HarnessUpdateStateRecord => ({
  harnessId: row.harness_id,
  info: {
    updateAvailable: row.update_available === 1,
    ...(row.installed_version === null ? {} : { installedVersion: row.installed_version }),
    ...(row.latest_version === null ? {} : { latestVersion: row.latest_version }),
    ...(row.source === null ? {} : { source: row.source }),
    ...(row.install_origin === null ? {} : { installOrigin: row.install_origin }),
    ...(row.channel === null ? {} : { channel: row.channel }),
    ...(row.checked_at === null ? {} : { checkedAt: row.checked_at })
  }
})

export const updateFromRow = (row: UpdateRow): UpdateInfo => ({
  currentVersion: row.current_version,
  latestVersion: row.latest_version,
  updateAvailable: row.update_available === 1,
  channel: row.channel,
  ...(row.checked_at === null ? {} : { checkedAt: row.checked_at }),
  migrationState: row.migration_state
})

export const mcpServerFromRow = (row: McpServerRow): McpServerRecord => ({
  id: row.id,
  name: row.name,
  kind: row.kind,
  canEdit: row.kind === "managed",
  canRemove: row.kind === "managed",
  transport: row.transport,
  ...(row.url === null ? {} : { url: row.url }),
  ...(row.command === null ? {} : { command: row.command }),
  args: JSON.parse(row.args) as ReadonlyArray<string>,
  enabled: row.enabled === 1,
  authType: row.auth_type,
  ...(row.oauth_scope === null ? {} : { oauthScope: row.oauth_scope }),
  connectionState: row.connection_state,
  toolCount: row.tool_count,
  ...(row.detail === null ? {} : { detail: row.detail }),
  ...(row.secret_cipher === null ? {} : { secretCipher: row.secret_cipher }),
  createdAt: row.created_at,
  updatedAt: row.updated_at
})

export const nativeMcpRemovalFromRow = (row: NativeMcpRemovalRow): NativeMcpRemovalRecord => ({
  configPath: row.config_path,
  fragment: row.fragment,
  harnessId: row.harness_id,
  id: row.id,
  removedAt: row.removed_at,
  ...(row.restored_at === null ? {} : { restoredAt: row.restored_at }),
  serverName: row.server_name
})
