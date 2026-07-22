import type {
  AttachmentKind,
  AttachmentRef,
  BackgroundTask,
  CreateProjectRequest,
  CreateSessionRequest,
  DataUpgradeProgress,
  EventEnvelope,
  EventKind,
  FileMetadata,
  Harness,
  HarnessAccount,
  HarnessAuthState,
  McpAuthType,
  McpConnectionState,
  McpServer,
  McpTransport,
  NativeMcpRemoval,
  Project,
  ProjectLocation,
  PromptQueueItem,
  QuestionPayload,
  SessionDetail,
  SessionGoal,
  SessionSummary,
  TranscriptItem,
  TranscriptItemDetails,
  TranscriptPage,
  HarnessUpdateInfo,
  UpdateProjectRequest,
  UpdateSessionRequest,
  UpdateInfo,
  UpsertWorkspaceNotesRequest,
  UpsertWorkspaceRequest,
  Workspace,
  WorkspaceNotes,
  Worktree
} from "@codevisor/api"
import { isoTimestamp, SessionGoal as SessionGoalSchema } from "@codevisor/api"
import Database from "better-sqlite3"
import { createHash, randomBytes, randomUUID } from "node:crypto"
import { Context, Effect, Layer, Schema } from "effect"
import { resolveSessionCwd, worktreePath } from "./paths.js"

export {
  managedRepoPath,
  managedReposRoot,
  resolveSessionCwd,
  worktreePath,
  worktreesRoot
} from "./paths.js"

export class DatabaseError extends Schema.TaggedErrorClass<DatabaseError>()("DatabaseError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface CodevisorDatabaseConfig {
  readonly filename: string
  readonly serverId: string
  /// Synchronous by design: migrations use better-sqlite3 and report after
  /// every durable batch. The app-hosted server writes this to a sidecar file
  /// that remains readable while the HTTP server is still booting.
  readonly onDataUpgradeProgress?: (progress: DataUpgradeProgress) => void
}

interface ProjectRow {
  readonly id: string
  readonly name: string
  readonly is_archived: number
  readonly symbol_name: string
  readonly origin: Project["origin"]
  readonly created_at: string
  readonly repo_url: string | null
}

interface ProjectLocationRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly folder_path: string
  readonly created_at: string
}

interface WorktreeRow {
  readonly id: string
  readonly project_id: string
  readonly server_id: string
  readonly name: string
  readonly branch: string
  readonly created_at: string
}

interface WorkspaceRow {
  readonly id: string
  readonly server_id: string
  readonly project_id: string
  readonly name: string
  readonly has_custom_name: number
  readonly symbol_name: string | null
  readonly root_directory: string | null
  readonly is_archived: number
  readonly created_at: string
  readonly updated_at: string | null
}

interface WorkspaceNotesRow {
  readonly workspace_id: string
  readonly content: string
  readonly format: string
  readonly updated_at: string
}

interface SessionRow {
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
  readonly worktree_name: string | null
  readonly workspace_id: string | null
  readonly created_at: string
  readonly updated_at: string | null
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
}

interface HarnessAccountRow {
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

interface McpServerRow {
  readonly id: string
  readonly name: string
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

interface ConversationRow {
  readonly id: string
  readonly role: "user" | "assistant" | "system"
  readonly message_id: string | null
  readonly text: string
  readonly created_at: string
  readonly is_generating: number
  readonly attachments: string | null
}

interface EventRow {
  readonly id: number
  readonly server_id: string
  readonly kind: EventKind
  readonly subject_id: string
  readonly created_at: string
  readonly payload: string
  readonly transcript_item_id: string | null
}

interface TranscriptRow {
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

interface ChatItemRow {
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

interface SessionEventRow {
  readonly session_id: string
  readonly revision: number
  readonly global_event_id: number | null
  readonly server_id: string
  readonly kind: EventKind
  readonly created_at: string
  readonly payload: string
  readonly chat_item_id: string | null
}

interface SessionActionRow {
  readonly session_id: string
  readonly client_action_id: string
  readonly action_kind: string
  readonly response: string
  readonly created_at: string
}

interface PromptQueueRow {
  readonly id: string
  readonly session_id: string
  readonly text: string
  readonly created_at: string
  readonly updated_at: string
  readonly attachments: string | null
  readonly state: "pending" | "processing"
}

interface FileRow {
  readonly id: string
  readonly name: string
  readonly mime_type: string
  readonly size_bytes: number
  readonly sha256: string
  readonly kind: AttachmentKind
  readonly created_at: string
}

interface UpdateRow {
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

interface HarnessPendingUpdateRow {
  readonly harness_id: string
  readonly state: "pending" | "running"
  readonly target_version: string | null
  readonly requested_at: string
  readonly started_at: string | null
  readonly timeout_at: string | null
}

interface HarnessUpdateStateRow {
  readonly harness_id: string
  readonly installed_version: string | null
  readonly latest_version: string | null
  readonly update_available: number
  readonly source: string | null
  readonly install_origin: string | null
  readonly channel: string | null
  readonly checked_at: string | null
}

interface Migration {
  readonly id: number
  readonly name: string
  readonly sql: string
  /** Runs inside the migration transaction, after `sql`; use for backfills that need config values. */
  readonly run?: (sqlite: Database.Database, config: CodevisorDatabaseConfig) => void
}

const migrations: ReadonlyArray<Migration> = [
  {
    id: 1,
    name: "initial",
    sql: `
      create table if not exists workspaces (
        id text primary key,
        name text not null,
        folder_path text not null unique,
        is_archived integer not null default 0,
        symbol_name text not null default 'folder',
        origin text not null,
        created_at text not null
      );

      create table if not exists sessions (
        id text primary key,
        workspace_id text not null references workspaces(id) on delete cascade,
        server_id text not null,
        harness_id text not null,
        agent_session_id text,
        title text not null,
        origin text not null,
        is_archived integer not null default 0,
        created_at text not null,
        updated_at text,
        usage_used integer,
        usage_size integer,
        cost_amount real,
        cost_currency text
      );

      create table if not exists conversation_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        role text not null,
        text text not null,
        created_at text not null,
        is_generating integer not null default 0
      );

      create table if not exists events (
        id integer primary key autoincrement,
        server_id text not null,
        kind text not null,
        subject_id text not null,
        created_at text not null,
        payload text not null
      );

      create table if not exists harness_settings (
        harness_id text primary key,
        enabled integer not null
      );

      create table if not exists auth_tokens (
        id text primary key,
        token_hash text not null unique,
        scope text not null,
        created_at text not null
      );

      create table if not exists update_state (
        id integer primary key check (id = 1),
        current_version text not null,
        latest_version text not null,
        update_available integer not null,
        channel text not null,
        checked_at text,
        migration_state text not null
      );

      create table if not exists backfill_jobs (
        id text primary key,
        name text not null,
        state text not null,
        cursor text,
        updated_at text not null
      );
    `
  },
  {
    id: 2,
    name: "session action idempotency",
    sql: `
      create table if not exists session_actions (
        session_id text not null references sessions(id) on delete cascade,
        client_action_id text not null,
        action_kind text not null,
        response text not null,
        created_at text not null,
        primary key (session_id, client_action_id)
      );
    `
  },
  {
    id: 3,
    name: "conversation message ids",
    sql: `
      alter table conversation_items add column message_id text;
      create index if not exists conversation_items_session_message_idx
        on conversation_items(session_id, message_id);
    `
  },
  {
    id: 4,
    name: "session prompt queue",
    sql: `
      create table if not exists prompt_queue_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        text text not null,
        created_at text not null,
        updated_at text not null
      );

      create index if not exists prompt_queue_items_session_created_idx
        on prompt_queue_items(session_id, created_at);
    `
  },
  {
    id: 5,
    name: "projects and worktrees",
    sql: `
      create table if not exists projects (
        id text primary key,
        name text not null,
        is_archived integer not null default 0,
        symbol_name text not null default 'folder',
        origin text not null,
        created_at text not null
      );

      insert into projects (id, name, is_archived, symbol_name, origin, created_at)
        select id, name, is_archived, symbol_name, origin, created_at from workspaces;

      create table if not exists project_locations (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        folder_path text not null,
        created_at text not null,
        unique (project_id, server_id),
        unique (server_id, folder_path)
      );

      create table if not exists worktrees (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        name text not null,
        branch text not null,
        created_at text not null,
        unique (project_id, server_id, name)
      );

      create table if not exists sessions_next (
        id text primary key,
        project_id text not null references projects(id) on delete cascade,
        server_id text not null,
        harness_id text not null,
        agent_session_id text,
        title text not null,
        origin text not null,
        is_archived integer not null default 0,
        worktree_name text,
        created_at text not null,
        updated_at text,
        usage_used integer,
        usage_size integer,
        cost_amount real,
        cost_currency text
      );

      insert into sessions_next (
        id, project_id, server_id, harness_id, agent_session_id, title, origin,
        is_archived, created_at, updated_at, usage_used, usage_size, cost_amount, cost_currency
      )
        select
          id, workspace_id, server_id, harness_id, agent_session_id, title, origin,
          is_archived, created_at, updated_at, usage_used, usage_size, cost_amount, cost_currency
        from sessions;

      drop table sessions;
      alter table sessions_next rename to sessions;
    `,
    run: (sqlite, config) => {
      sqlite
        .prepare(
          `insert into project_locations (id, project_id, server_id, folder_path, created_at)
           select id, id, ?, folder_path, created_at from workspaces`
        )
        .run(config.serverId)
      sqlite.exec("drop table workspaces")
    }
  },
  {
    id: 6,
    name: "file attachments",
    sql: `
      create table if not exists files (
        id text primary key,
        name text not null,
        mime_type text not null,
        size_bytes integer not null,
        sha256 text not null,
        kind text not null,
        created_at text not null,
        data blob not null
      );

      alter table conversation_items add column attachments text;
      alter table prompt_queue_items add column attachments text;
    `
  },
  {
    id: 7,
    name: "paginated transcript projection",
    sql: `
      alter table events add column transcript_item_id text;

      create index if not exists events_subject_id_idx on events(subject_id, id);
      create index if not exists events_transcript_item_idx
        on events(subject_id, transcript_item_id, id);

      create table if not exists transcript_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        sequence integer not null,
        role text not null check(role in ('user', 'assistant')),
        text text not null default '',
        created_at text not null,
        updated_at text not null,
        is_generating integer not null default 0,
        has_details integer not null default 0,
        turn_id text,
        started_at text,
        ended_at text,
        stop_reason text,
        stop_detail text,
        plan_document text,
        attachments text,
        revision integer not null default 1,
        unique(session_id, sequence),
        unique(session_id, turn_id)
      );

      create index if not exists transcript_items_session_sequence_idx
        on transcript_items(session_id, sequence desc);

      create table if not exists transcript_projection_state (
        session_id text primary key references sessions(id) on delete cascade,
        next_sequence integer not null default 0,
        current_item_id text references transcript_items(id) on delete set null,
        source_cursor integer not null default 0
      );

      create table if not exists transcript_routes (
        session_id text not null references sessions(id) on delete cascade,
        route_key text not null,
        item_id text not null references transcript_items(id) on delete cascade,
        primary key(session_id, route_key)
      );

      alter table backfill_jobs add column completed integer not null default 0;
      alter table backfill_jobs add column total integer not null default 0;
      alter table backfill_jobs add column error text;
    `
  },
  {
    id: 8,
    name: "canonical session chat store",
    sql: `
      alter table sessions add column revision integer not null default 0;

      create table if not exists chat_items (
        id text primary key,
        session_id text not null references sessions(id) on delete cascade,
        position integer not null,
        role text not null check(role in ('user', 'assistant', 'system', 'tool')),
        message_id text,
        status text not null check(status in ('streaming', 'complete', 'failed')),
        created_at text not null,
        updated_at text not null,
        turn_id text,
        started_at text,
        completed_at text,
        stop_reason text,
        stop_detail text,
        attachments text,
        has_details integer not null default 0,
        revision integer not null default 1,
        unique(session_id, position),
        unique(session_id, turn_id)
      );

      create index if not exists chat_items_session_position_idx
        on chat_items(session_id, position desc);

      create table if not exists chat_parts (
        id text primary key,
        item_id text not null references chat_items(id) on delete cascade,
        position integer not null,
        kind text not null,
        text text,
        data_json text,
        revision integer not null default 1,
        unique(item_id, position)
      );

      create index if not exists chat_parts_item_position_idx
        on chat_parts(item_id, position);

      create table if not exists session_chat_state (
        session_id text primary key references sessions(id) on delete cascade,
        next_position integer not null default 0,
        current_item_id text references chat_items(id) on delete set null
      );

      create table if not exists chat_item_routes (
        session_id text not null references sessions(id) on delete cascade,
        route_key text not null,
        item_id text not null references chat_items(id) on delete cascade,
        primary key(session_id, route_key)
      );

      create table if not exists session_events (
        session_id text not null references sessions(id) on delete cascade,
        revision integer not null,
        global_event_id integer unique,
        server_id text not null,
        kind text not null,
        created_at text not null,
        payload text not null,
        chat_item_id text references chat_items(id) on delete set null,
        primary key(session_id, revision)
      );

      create index if not exists session_events_item_idx
        on session_events(session_id, chat_item_id, revision);
    `
  },
  {
    id: 9,
    name: "harness accounts and session identity",
    sql: `
      create table if not exists harness_accounts (
        id text primary key,
        harness_id text not null,
        profile_kind text not null check(profile_kind in ('default', 'managed')),
        profile_key text,
        label text not null,
        email text,
        organization_id text,
        auth_method text,
        auth_state text not null default 'checking',
        can_login integer not null default 1,
        can_logout integer not null default 0,
        last_checked_at text,
        detail text,
        created_at text not null,
        updated_at text not null,
        removed_at text
      );

      create unique index if not exists harness_accounts_default_idx
        on harness_accounts(harness_id)
        where profile_kind = 'default' and removed_at is null;

      create unique index if not exists harness_accounts_profile_idx
        on harness_accounts(harness_id, profile_key)
        where profile_key is not null and removed_at is null;

      create table if not exists harness_account_selection (
        harness_id text primary key,
        account_id text not null references harness_accounts(id)
      );

      alter table sessions add column harness_account_id text references harness_accounts(id);
      create index if not exists sessions_harness_account_idx on sessions(harness_account_id);
    `
  },
  {
    id: 10,
    name: "accurate worked detail markers",
    sql: "",
    run: (sqlite) => {
      const itemIdsWithDetails = new Set<string>()
      const detailEvents = sqlite
        .prepare(
          `select chat_item_id, payload from session_events
           where chat_item_id is not null and kind = 'session.output'
           order by session_id, revision asc`
        )
        .iterate() as Iterable<{
        readonly chat_item_id: string
        readonly payload: string
      }>
      for (const event of detailEvents) {
        const payload = parseJsonRecord(event.payload)
        if (payload !== undefined && isRenderableWorkedEvent(payload)) {
          itemIdsWithDetails.add(event.chat_item_id)
        }
      }

      const items = sqlite
        .prepare("select id, has_details from chat_items where role = 'assistant'")
        .all() as ReadonlyArray<{ readonly id: string; readonly has_details: number }>
      const updateItem = sqlite.prepare(
        `update chat_items set has_details = ?, revision = revision + 1
         where id = ? and has_details != ?`
      )

      for (const item of items) {
        const value = itemIdsWithDetails.has(item.id) ? 1 : 0
        updateItem.run(value, item.id, value)
      }
    }
  },
  {
    id: 11,
    name: "mcp servers",
    sql: `
      create table if not exists mcp_servers (
        id text primary key,
        name text not null,
        transport text not null check(transport in ('http', 'stdio')),
        url text,
        command text,
        args text not null default '[]',
        enabled integer not null default 1,
        auth_type text not null default 'none' check(auth_type in ('none', 'bearer', 'oauth')),
        oauth_scope text,
        connection_state text not null default 'disconnected',
        tool_count integer not null default 0,
        detail text,
        secret_cipher text,
        created_at text not null,
        updated_at text not null
      );

      create index if not exists mcp_servers_enabled_idx on mcp_servers(enabled);
    `
  },
  {
    id: 12,
    name: "scoped mcp settings",
    sql: `
      create table if not exists project_mcp_settings (
        project_id text not null references projects(id) on delete cascade,
        mcp_server_id text not null references mcp_servers(id) on delete cascade,
        enabled integer not null,
        primary key (project_id, mcp_server_id)
      );

      create table if not exists session_mcp_settings (
        session_id text not null references sessions(id) on delete cascade,
        mcp_server_id text not null references mcp_servers(id) on delete cascade,
        enabled integer not null,
        primary key (session_id, mcp_server_id)
      );
    `
  },
  {
    id: 13,
    name: "durable live session state",
    sql: `
      alter table sessions add column pending_question text;
      alter table sessions add column background_tasks text not null default '[]';
    `
  },
  {
    id: 14,
    name: "durable prompt dispatch",
    sql: `
      alter table prompt_queue_items add column state text not null default 'pending'
        check(state in ('pending', 'processing'));

      create index if not exists prompt_queue_items_session_state_created_idx
        on prompt_queue_items(session_id, state, created_at);
    `
  },
  {
    id: 15,
    name: "retryable assistant turns",
    sql: `
      alter table transcript_items add column retryable integer not null default 0;
      alter table chat_items add column retryable integer not null default 0;
    `
  },
  {
    id: 16,
    name: "Codevisor session origins",
    sql: `
      update projects set origin = 'codevisor' where origin = 'herdman';
      update sessions set origin = 'codevisor' where origin = 'herdman';
      update events
        set payload = json_set(payload, '$.origin', 'codevisor')
        where json_valid(payload) and json_extract(payload, '$.origin') = 'herdman';
      update session_events
        set payload = json_set(payload, '$.origin', 'codevisor')
        where json_valid(payload) and json_extract(payload, '$.origin') = 'herdman';
    `
  },
  {
    id: 17,
    name: "instance identity",
    sql: `
      create table if not exists instance_meta (
        key text primary key,
        value text not null
      );
    `
  },
  {
    id: 18,
    name: "project git remotes",
    sql: `
      alter table projects add column repo_url text;
    `
  },
  {
    id: 19,
    name: "detailed durable session usage",
    sql: `
      alter table sessions add column input_tokens integer;
      alter table sessions add column cached_input_tokens integer;
      alter table sessions add column output_tokens integer;
      alter table sessions add column reasoning_output_tokens integer;
      alter table sessions add column total_tokens integer;
      alter table sessions add column cost_kind text check(cost_kind in ('reported', 'estimated'));
    `
  },
  {
    id: 20,
    name: "user-set session titles",
    sql: `
      alter table sessions add column title_is_user_set integer not null default 0
        check(title_is_user_set in (0, 1));

      -- Older databases did not retain title provenance. Protect every
      -- existing title rather than risk replacing a user-authored one.
      update sessions set title_is_user_set = 1;
    `
  },
  {
    id: 21,
    name: "pane workspaces",
    // Note: an unrelated table also named `workspaces` (the pre-migration-5
    // spelling of projects) was dropped by migration 5, so the name is free
    // on every database that reaches this point.
    sql: `
      create table if not exists workspaces (
        id text primary key,
        server_id text not null,
        project_id text not null references projects(id) on delete cascade,
        name text not null,
        has_custom_name integer not null default 0 check(has_custom_name in (0, 1)),
        symbol_name text,
        root_directory text,
        is_archived integer not null default 0 check(is_archived in (0, 1)),
        created_at text not null,
        updated_at text
      );

      alter table sessions add column workspace_id text references workspaces(id);
      create index if not exists sessions_workspace_id on sessions(workspace_id);
    `
  },
  {
    id: 22,
    name: "workspace notes",
    sql: `
      create table if not exists workspace_notes (
        workspace_id text primary key references workspaces(id) on delete cascade,
        content text not null,
        format text not null default 'attributed-string-v1',
        updated_at text not null
      );
    `
  },
  {
    id: 23,
    name: "harness update state",
    sql: `
      create table if not exists harness_update_state (
        harness_id text primary key,
        installed_version text,
        latest_version text,
        update_available integer not null default 0 check(update_available in (0, 1)),
        source text,
        install_origin text,
        channel text,
        checked_at text
      );
    `
  },
  {
    id: 24,
    name: "harness pending updates",
    sql: `
      create table if not exists harness_pending_updates (
        harness_id text primary key,
        state text not null check(state in ('pending', 'running')),
        target_version text,
        requested_at text not null,
        started_at text,
        timeout_at text
      );
    `
  },
  {
    id: 25,
    name: "native config safety",
    sql: `
      create table if not exists native_config_backups (
        file_path text primary key,
        backup_path text not null,
        created_at text not null
      );

      create table if not exists native_mcp_removals (
        id text primary key,
        harness_id text not null,
        config_path text not null,
        server_name text not null,
        fragment text not null,
        removed_at text not null,
        restored_at text
      );
    `
  },
  {
    id: 26,
    name: "durable session config selections",
    sql: `
      alter table sessions add column config_selections text not null default '{}';
    `
  }
]

// A row count is not a render-cost bound: one assistant item can contain a
// 20k-character essay. Keep reverse pages small enough for clients to parse
// and lay out without a visible hitch, while always returning at least the
// newest row so a single oversized answer can still be reached.
const maxInitialTranscriptPageCharacters = 24_000
const maxOlderTranscriptPageCharacters = 64_000

type JsonRecord = Record<string, unknown>

const jsonRecord = (value: unknown): JsonRecord | undefined =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as JsonRecord)
    : undefined

const parseJsonRecord = (raw: string): JsonRecord | undefined => {
  try {
    return jsonRecord(JSON.parse(raw))
  } catch {
    return undefined
  }
}

const sessionConfigSelectionsFromRaw = (raw: string): Readonly<Record<string, string>> => {
  const record = parseJsonRecord(raw)
  if (record === undefined) return {}
  return Object.fromEntries(
    Object.entries(record).filter(
      (entry): entry is [string, string] => typeof entry[1] === "string"
    )
  )
}

const pendingQuestionFromRaw = (raw: string | null): QuestionPayload | undefined =>
  raw === null ? undefined : (JSON.parse(raw) as QuestionPayload)

const backgroundTasksFromRaw = (raw: string): ReadonlyArray<BackgroundTask> =>
  JSON.parse(raw) as ReadonlyArray<BackgroundTask>

const payloadText = (payload: JsonRecord): string | undefined => {
  if (typeof payload.text === "string") {
    return payload.text
  }
  const content = jsonRecord(payload.content)
  return content?.type === "text" && typeof content.text === "string" ? content.text : undefined
}

/** Whether replaying this non-answer update can produce visible assistant-turn
 * detail. Transport/config updates and empty thought chunks must not create an
 * otherwise empty assistant item. */
const hasRenderableWorkedDetail = (payload: JsonRecord): boolean => {
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  switch (update) {
    case "tool_call":
    case "tool_call_update":
    case "question":
    case "question_resolved":
    case "context_compaction":
      return true
    case "agent_thought_chunk":
      return (payloadText(payload)?.trim().length ?? 0) > 0
    case "agent_message_chunk":
      // A zero-length commentary chunk can retroactively classify the earlier
      // text span with the same message id as work rather than final output.
      return (
        (payloadText(payload)?.trim().length ?? 0) > 0 ||
        (payload.phase === "commentary" && typeof payload.messageId === "string")
      )
    default:
      return false
  }
}

const conversationEventPayload = (
  payload: JsonRecord
):
  | {
      readonly role: "user" | "assistant" | "system"
      readonly text: string
      readonly messageId?: string
      readonly attachments?: ReadonlyArray<AttachmentRef>
    }
  | undefined => {
  const role = payload.role
  const direct =
    (role === "user" || role === "assistant" || role === "system") &&
    typeof payload.text === "string" &&
    (payload.messageId === undefined || typeof payload.messageId === "string") &&
    (payload.attachments === undefined || Array.isArray(payload.attachments))
  if (direct) {
    return {
      role,
      text: payload.text as string,
      ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {}),
      ...(Array.isArray(payload.attachments)
        ? { attachments: payload.attachments as ReadonlyArray<AttachmentRef> }
        : {})
    }
  }
  if (
    typeof payload.sessionUpdate !== "string" ||
    typeof payload.parentToolCallId === "string" ||
    payload.phase === "commentary"
  ) {
    return undefined
  }
  const text = payloadText(payload)
  if (text === undefined) return undefined
  if (payload.sessionUpdate === "user_message_chunk") {
    return {
      role: "user",
      text,
      ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
    }
  }
  if (payload.sessionUpdate === "agent_message_chunk") {
    return {
      role: "assistant",
      text,
      ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
    }
  }
  return undefined
}

const isRenderableWorkedEvent = (payload: JsonRecord): boolean =>
  conversationEventPayload(payload) === undefined && hasRenderableWorkedDetail(payload)

const canonicalChatBackfillId = "canonical-session-chat-v1"

const reportDataUpgrade = (
  config: CodevisorDatabaseConfig,
  progress: DataUpgradeProgress
): void => {
  config.onDataUpgradeProgress?.(progress)
}

const chatState = (
  sqlite: Database.Database,
  sessionId: string
): { next_position: number; current_item_id: string | null } => {
  sqlite
    .prepare(
      `insert into session_chat_state (session_id, next_position, current_item_id)
       values (?, 0, null) on conflict(session_id) do nothing`
    )
    .run(sessionId)
  return sqlite
    .prepare("select next_position, current_item_id from session_chat_state where session_id = ?")
    .get(sessionId) as { next_position: number; current_item_id: string | null }
}

const upsertChatPart = (
  sqlite: Database.Database,
  itemId: string,
  kind: "text" | "plan",
  text: string
): void => {
  const position = kind === "text" ? 0 : 1
  sqlite
    .prepare(
      `insert into chat_parts (id, item_id, position, kind, text, data_json, revision)
       values (?, ?, ?, ?, ?, null, 1)
       on conflict(item_id, position) do update set
         kind = excluded.kind, text = excluded.text, revision = chat_parts.revision + 1`
    )
    .run(`${itemId}:${kind}`, itemId, position, kind, text)
}

const createChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  role: "user" | "assistant" | "system" | "tool",
  createdAt: string,
  options: {
    readonly id?: string
    readonly position?: number
    readonly text?: string
    readonly messageId?: string
    readonly planDocument?: string
    readonly status: "streaming" | "complete" | "failed"
    readonly turnId?: string
    readonly startedAt?: string
    readonly completedAt?: string
    readonly stopReason?: string
    readonly stopDetail?: string
    readonly retryable?: boolean
    readonly attachments?: ReadonlyArray<AttachmentRef>
    readonly hasDetails?: boolean
    readonly revision?: number
  }
): string => {
  const state = chatState(sqlite, sessionId)
  const id = options.id ?? randomUUID()
  const position = options.position ?? state.next_position
  sqlite
    .prepare(
      `insert into chat_items (
        id, session_id, position, role, message_id, status, created_at, updated_at, turn_id,
        started_at, completed_at, stop_reason, stop_detail, retryable, attachments, has_details, revision
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do nothing`
    )
    .run(
      id,
      sessionId,
      position,
      role,
      options.messageId ?? null,
      options.status,
      createdAt,
      options.completedAt ?? createdAt,
      options.turnId ?? null,
      options.startedAt ?? null,
      options.completedAt ?? null,
      options.stopReason ?? null,
      options.stopDetail ?? null,
      Number(options.retryable === true),
      serializeAttachments(options.attachments),
      options.hasDetails === true ? 1 : 0,
      options.revision ?? 1
    )
  if (options.text !== undefined) upsertChatPart(sqlite, id, "text", options.text)
  if (options.planDocument !== undefined) upsertChatPart(sqlite, id, "plan", options.planDocument)
  sqlite
    .prepare(
      `update session_chat_state set
         next_position = max(next_position, ?),
         current_item_id = case when ? = 'assistant' and ? = 'streaming' then ? else current_item_id end
       where session_id = ?`
    )
    .run(position + 1, role, options.status, id, sessionId)
  return id
}

const setChatRoute = (
  sqlite: Database.Database,
  sessionId: string,
  key: string,
  itemId: string
): void => {
  sqlite
    .prepare(
      `insert into chat_item_routes (session_id, route_key, item_id) values (?, ?, ?)
       on conflict(session_id, route_key) do update set item_id = excluded.item_id`
    )
    .run(sessionId, key, itemId)
}

const chatRoute = (sqlite: Database.Database, sessionId: string, key: string): string | undefined =>
  (
    sqlite
      .prepare("select item_id from chat_item_routes where session_id = ? and route_key = ?")
      .get(sessionId, key) as { item_id: string } | undefined
  )?.item_id

const ensureAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  createdAt: string,
  turnId?: string
): string => {
  if (turnId !== undefined) {
    const routed = chatRoute(sqlite, sessionId, `turn:${turnId}`)
    if (routed !== undefined) return routed
  }
  const current = chatState(sqlite, sessionId).current_item_id
  if (current !== null) return current
  const id = createChatItem(sqlite, sessionId, "assistant", createdAt, {
    status: "streaming",
    ...(turnId === undefined ? {} : { turnId })
  })
  if (turnId !== undefined) setChatRoute(sqlite, sessionId, `turn:${turnId}`, id)
  return id
}

const chatAssistantSummary = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string
): { text: string; planDocument?: string; messageId?: string } => {
  const rows = sqlite
    .prepare(
      `select payload from session_events
       where session_id = ? and chat_item_id = ? and kind = 'session.output'
       order by revision asc`
    )
    .all(sessionId, itemId) as ReadonlyArray<{ payload: string }>
  const spans: Array<{ chunks: Array<string>; phase?: string; messageId?: string }> = []
  const indexById = new Map<string, number>()
  let anonymous = 0
  let planDocument: string | undefined
  for (const row of rows) {
    const payload = jsonRecord(JSON.parse(row.payload))
    /* v8 ignore next -- session events are encoded from object payloads; this only guards manually corrupted rows. */
    if (payload === undefined) continue
    if (payload.sessionUpdate === "plan_document" && typeof payload.markdown === "string") {
      planDocument = payload.markdown
      continue
    }
    const direct = payload.role === "assistant" && typeof payload.text === "string"
    if (
      !direct &&
      (payload.sessionUpdate !== "agent_message_chunk" ||
        typeof payload.parentToolCallId === "string")
    ) {
      anonymous += 1
      continue
    }
    /* v8 ignore next -- projected answer events always carry text; this only guards manually corrupted rows. */
    const text = payloadText(payload) ?? ""
    if (text.length === 0) continue
    const messageId =
      typeof payload.messageId === "string" ? payload.messageId : `anonymous:${anonymous}`
    let index = indexById.get(messageId)
    if (index === undefined) {
      index = spans.length
      indexById.set(messageId, index)
      // Anonymous spans have no provider identity to hand back to clients.
      spans.push(typeof payload.messageId === "string" ? { chunks: [], messageId } : { chunks: [] })
    }
    const span = spans[index]
    /* v8 ignore next -- index is created from spans.length immediately before lookup. */
    if (span === undefined) continue
    span.chunks.push(text)
    if (typeof payload.phase === "string") span.phase = payload.phase
  }
  const final = [...spans].reverse().find((span) => span.phase !== "commentary")
  return {
    text: final?.chunks.join("") ?? "",
    ...(planDocument === undefined ? {} : { planDocument }),
    ...(final?.messageId === undefined ? {} : { messageId: final.messageId })
  }
}

/// Goal updates live in the durable session log rather than the transcript
/// projection. Snapshot the newest one alongside the transcript cursor so a
/// client that opens after the update cannot skip it by subscribing from the
/// newer cursor.
const sessionGoalSnapshot = (
  sqlite: Database.Database,
  sessionId: string
): SessionGoal | undefined => {
  const row = sqlite
    .prepare(
      `select payload from session_events
       where session_id = ? and kind = 'session.updated'
         and (json_type(payload, '$.goal') = 'object'
           or json_extract(payload, '$.goalCleared') = 1)
       order by revision desc limit 1`
    )
    .get(sessionId) as { readonly payload: string } | undefined
  if (row === undefined) return undefined
  const payload = jsonRecord(JSON.parse(row.payload))
  if (payload?.goalCleared === true) return undefined
  try {
    return Schema.decodeUnknownSync(SessionGoalSchema)(payload?.goal)
  } catch {
    /* v8 ignore next -- only manually corrupted session events can reach this path. */
    return undefined
  }
}

const finishAssistantChatItem = (
  sqlite: Database.Database,
  sessionId: string,
  itemId: string,
  completedAt: string,
  stopReason?: string,
  stopDetail?: string,
  retryable = false,
  failed = false
): void => {
  const summary = chatAssistantSummary(sqlite, sessionId, itemId)
  upsertChatPart(sqlite, itemId, "text", summary.text)
  if (summary.planDocument !== undefined) {
    upsertChatPart(sqlite, itemId, "plan", summary.planDocument)
  }
  sqlite
    .prepare(
      `update chat_items set status = ?, completed_at = ?, updated_at = ?,
       stop_reason = coalesce(?, stop_reason), stop_detail = coalesce(?, stop_detail),
       retryable = ?,
       revision = revision + 1 where id = ?`
    )
    .run(
      failed ? "failed" : "complete",
      completedAt,
      completedAt,
      stopReason ?? null,
      stopDetail ?? null,
      retryable ? 1 : 0,
      itemId
    )
}

const projectChatEvent = (sqlite: Database.Database, event: SessionEventRow): void => {
  const payload = jsonRecord(JSON.parse(event.payload))
  if (payload === undefined) return
  const sessionId = event.session_id
  let itemId: string | undefined

  if (event.kind === "session.updated" && payload.turnState === "started") {
    const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
    itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at, turnId)
    sqlite
      .prepare(
        "update chat_items set started_at = coalesce(started_at, ?), updated_at = ? where id = ?"
      )
      .run(event.created_at, event.created_at, itemId)
  } else if (event.kind === "session.output") {
    const conversation = conversationEventPayload(payload)
    if (conversation?.role === "user" || conversation?.role === "system") {
      itemId = createChatItem(sqlite, sessionId, conversation.role, event.created_at, {
        text: conversation.text,
        ...(conversation.messageId === undefined ? {} : { messageId: conversation.messageId }),
        status: "complete",
        ...(conversation.attachments === undefined ? {} : { attachments: conversation.attachments })
      })
    } else if (conversation?.role === "assistant") {
      itemId = ensureAssistantChatItem(sqlite, sessionId, event.created_at)
      sqlite
        .prepare(
          `insert into chat_parts (id, item_id, position, kind, text, data_json, revision)
           values (?, ?, 0, 'text', ?, null, 1)
           on conflict(item_id, position) do update set
             text = coalesce(chat_parts.text, '') || excluded.text,
             revision = chat_parts.revision + 1`
        )
        .run(`${itemId}:text`, itemId, conversation.text)
      sqlite
        .prepare(
          `update chat_items set message_id = coalesce(message_id, ?), updated_at = ?,
           revision = revision + 1 where id = ?`
        )
        .run(conversation.messageId ?? null, event.created_at, itemId)
    } else {
      const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
      // ACP agents can publish session-scoped metadata (available commands,
      // mode/config changes, usage) as `session.output` before the first
      // prompt. Those events remain in the session event log, but they must
      // not materialize an empty streaming assistant item ahead of the user's
      // first message. Only updates that can render inside an assistant turn
      // belong to the canonical chat projection.
      const rendersInAssistantTurn =
        hasRenderableWorkedDetail(payload) ||
        (update === "plan_document" && typeof payload.markdown === "string")
      if (update !== undefined && rendersInAssistantTurn) {
        const parent =
          typeof payload.parentToolCallId === "string" ? payload.parentToolCallId : undefined
        const toolId = typeof payload.toolCallId === "string" ? payload.toolCallId : undefined
        itemId =
          (parent === undefined ? undefined : chatRoute(sqlite, sessionId, `tool:${parent}`)) ??
          (toolId === undefined ? undefined : chatRoute(sqlite, sessionId, `tool:${toolId}`)) ??
          ensureAssistantChatItem(sqlite, sessionId, event.created_at)
        sqlite
          .prepare(
            `update chat_items set has_details = max(has_details, ?), updated_at = ?,
             revision = revision + 1 where id = ?`
          )
          .run(hasRenderableWorkedDetail(payload) ? 1 : 0, event.created_at, itemId)
        if (update === "plan_document" && typeof payload.markdown === "string") {
          upsertChatPart(sqlite, itemId, "plan", payload.markdown)
        }
        if (toolId !== undefined) setChatRoute(sqlite, sessionId, `tool:${toolId}`, itemId)
      }
    }
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
    const turnId = typeof payload.turnId === "string" ? payload.turnId : undefined
    itemId =
      (turnId === undefined ? undefined : chatRoute(sqlite, sessionId, `turn:${turnId}`)) ??
      chatState(sqlite, sessionId).current_item_id ??
      undefined
    if (itemId !== undefined) {
      finishAssistantChatItem(
        sqlite,
        sessionId,
        itemId,
        event.created_at,
        typeof payload.stopReason === "string" ? payload.stopReason : undefined,
        typeof payload.stopDetail === "string"
          ? payload.stopDetail
          : event.kind === "session.error" && typeof payload.message === "string"
            ? payload.message
            : undefined,
        payload.retryable === true,
        event.kind === "session.error"
      )
      sqlite
        .prepare("update session_chat_state set current_item_id = null where session_id = ?")
        .run(sessionId)
    }
  }

  if (itemId !== undefined) {
    sqlite
      .prepare("update session_events set chat_item_id = ? where session_id = ? and revision = ?")
      .run(itemId, sessionId, event.revision)
  }

  // A question is session-level blocking state, not merely transcript detail.
  // Keep a single current-state projection in the same transaction as the
  // append so reconnect snapshots cannot advance past the event while losing
  // the question needed to release the provider's pending continuation.
  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (
    event.kind === "session.output" &&
    update === "question" &&
    typeof payload.questionId === "string" &&
    Array.isArray(payload.questions)
  ) {
    sqlite
      .prepare("update sessions set pending_question = ? where id = ?")
      .run(event.payload, sessionId)
  } else if (
    event.kind === "session.output" &&
    update === "question_resolved" &&
    typeof payload.questionId === "string"
  ) {
    const current = sqlite
      .prepare("select pending_question from sessions where id = ?")
      .get(sessionId) as { readonly pending_question: string | null }
    const projected =
      current.pending_question === null ? undefined : parseJsonRecord(current.pending_question)
    if (projected?.questionId === payload.questionId) {
      sqlite.prepare("update sessions set pending_question = null where id = ?").run(sessionId)
    }
  } else if (
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  ) {
    sqlite.prepare("update sessions set pending_question = null where id = ?").run(sessionId)
  }
  if (event.kind === "session.updated" && Array.isArray(payload.backgroundTasks)) {
    sqlite
      .prepare("update sessions set background_tasks = ? where id = ?")
      .run(JSON.stringify(payload.backgroundTasks), sessionId)
  }
  if (
    (event.kind === "session.updated" || event.kind === "session.output") &&
    update === "usage_update"
  ) {
    const cost = jsonRecord(payload.cost)
    const finite = (value: unknown): number | null =>
      typeof value === "number" && Number.isFinite(value) ? value : null
    const costKind = cost?.kind === "reported" || cost?.kind === "estimated" ? cost.kind : null
    sqlite
      .prepare(
        `update sessions set
           usage_used = coalesce(?, usage_used), usage_size = coalesce(?, usage_size),
           input_tokens = coalesce(?, input_tokens),
           cached_input_tokens = coalesce(?, cached_input_tokens),
           output_tokens = coalesce(?, output_tokens),
           reasoning_output_tokens = coalesce(?, reasoning_output_tokens),
           total_tokens = coalesce(?, total_tokens),
           cost_amount = coalesce(?, cost_amount),
           cost_currency = coalesce(?, cost_currency),
           cost_kind = coalesce(?, cost_kind)
         where id = ?`
      )
      .run(
        finite(payload.used),
        finite(payload.size),
        finite(payload.inputTokens),
        finite(payload.cachedInputTokens),
        finite(payload.outputTokens),
        finite(payload.reasoningOutputTokens),
        finite(payload.totalTokens),
        finite(cost?.amount),
        typeof cost?.currency === "string" ? cost.currency : null,
        costKind,
        sessionId
      )
  }
}

const insertSessionEvent = (
  sqlite: Database.Database,
  row: Omit<SessionEventRow, "revision" | "chat_item_id"> & {
    readonly chat_item_id?: string | null
  }
): SessionEventRow => {
  const revision = Number(
    (
      sqlite
        .prepare("update sessions set revision = revision + 1 where id = ? returning revision")
        .get(row.session_id) as { revision: number }
    ).revision
  )
  const event: SessionEventRow = {
    ...row,
    revision,
    chat_item_id: row.chat_item_id ?? null
  }
  sqlite
    .prepare(
      `insert into session_events (
        session_id, revision, global_event_id, server_id, kind, created_at, payload, chat_item_id
      ) values (?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .run(
      event.session_id,
      event.revision,
      event.global_event_id,
      event.server_id,
      event.kind,
      event.created_at,
      event.payload,
      event.chat_item_id
    )
  return event
}

const copyTranscriptItemToChat = (sqlite: Database.Database, row: TranscriptRow): void => {
  const attachments = parseAttachments(row.attachments)
  const itemId = createChatItem(sqlite, row.session_id, row.role, row.created_at, {
    id: row.id,
    position: row.sequence,
    text: row.text,
    status: row.is_generating === 1 ? "streaming" : "complete",
    ...(row.plan_document === null ? {} : { planDocument: row.plan_document }),
    ...(row.turn_id === null ? {} : { turnId: row.turn_id }),
    ...(row.started_at === null ? {} : { startedAt: row.started_at }),
    ...(row.ended_at === null ? {} : { completedAt: row.ended_at }),
    ...(row.stop_reason === null ? {} : { stopReason: row.stop_reason }),
    ...(row.stop_detail === null ? {} : { stopDetail: row.stop_detail }),
    retryable: row.retryable === 1,
    ...(attachments === undefined ? {} : { attachments }),
    hasDetails: row.has_details === 1,
    revision: row.revision
  })
  if (row.turn_id !== null) setChatRoute(sqlite, row.session_id, `turn:${row.turn_id}`, itemId)
}

const runCanonicalChatBackfill = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): void => {
  const existing = sqlite
    .prepare("select state, completed, total from backfill_jobs where id = ?")
    .get(canonicalChatBackfillId) as { state: string; completed: number; total: number } | undefined
  if (existing?.state === "completed") {
    reportDataUpgrade(config, {
      state: "completed",
      id: canonicalChatBackfillId,
      name: "Updating chat history",
      completed: existing.total,
      total: existing.total
    })
    return
  }

  const transcriptTotal = Number(
    (sqlite.prepare("select count(*) as count from transcript_items").get() as { count: number })
      .count
  )
  const eventTotal = Number(
    (
      sqlite
        .prepare(
          `select count(*) as count from events
           where exists (select 1 from sessions where sessions.id = events.subject_id)`
        )
        .get() as { count: number }
    ).count
  )
  const sessionTotal = Number(
    (sqlite.prepare("select count(*) as count from sessions").get() as { count: number }).count
  )
  const total = Math.max(1, transcriptTotal + eventTotal + sessionTotal)
  let completed = Math.min(existing?.completed ?? 0, total)
  const progress = (state: DataUpgradeProgress["state"], error?: string): void => {
    const value: DataUpgradeProgress = {
      state,
      id: canonicalChatBackfillId,
      name: "Updating chat history",
      completed: state === "completed" ? total : Math.min(completed, total),
      total,
      ...(error === undefined ? {} : { error })
    }
    reportDataUpgrade(config, value)
  }
  sqlite
    .prepare(
      `insert into backfill_jobs (id, name, state, cursor, completed, total, error, updated_at)
       values (?, ?, 'running', null, ?, ?, null, ?)
       on conflict(id) do update set state = 'running', total = excluded.total,
         error = null, updated_at = excluded.updated_at`
    )
    .run(
      canonicalChatBackfillId,
      "Build canonical session chat store",
      completed,
      total,
      isoTimestamp()
    )
  progress("running")

  const checkpoint = (delta: number): void => {
    completed = Math.min(total, completed + delta)
    sqlite
      .prepare("update backfill_jobs set completed = ?, updated_at = ? where id = ?")
      .run(completed, isoTimestamp(), canonicalChatBackfillId)
    progress("running")
  }

  try {
    while (true) {
      const rows = sqlite
        .prepare(
          `select transcript_items.* from transcript_items
           left join chat_items on chat_items.id = transcript_items.id
           where chat_items.id is null order by transcript_items.rowid asc limit 100`
        )
        .all() as ReadonlyArray<TranscriptRow>
      if (rows.length === 0) break
      sqlite.transaction(() => {
        for (const row of rows) copyTranscriptItemToChat(sqlite, row)
      })()
      checkpoint(rows.length)
    }

    sqlite.exec(`
      insert into chat_item_routes (session_id, route_key, item_id)
        select transcript_routes.session_id, transcript_routes.route_key, transcript_routes.item_id
        from transcript_routes
        join chat_items on chat_items.id = transcript_routes.item_id
        on conflict(session_id, route_key) do nothing;
    `)

    while (true) {
      const rows = sqlite
        .prepare(
          `select events.* from events
           join sessions on sessions.id = events.subject_id
           left join session_events on session_events.global_event_id = events.id
           where session_events.global_event_id is null
           order by events.id asc limit 500`
        )
        .all() as ReadonlyArray<EventRow>
      if (rows.length === 0) break
      sqlite.transaction(() => {
        for (const row of rows) {
          const linkedItem =
            row.transcript_item_id !== null &&
            sqlite.prepare("select 1 from chat_items where id = ?").get(row.transcript_item_id) !==
              undefined
              ? row.transcript_item_id
              : null
          const event = insertSessionEvent(sqlite, {
            session_id: row.subject_id,
            global_event_id: row.id,
            server_id: row.server_id,
            kind: row.kind,
            created_at: row.created_at,
            payload: row.payload,
            chat_item_id: linkedItem
          })
          const hasTranscript =
            sqlite
              .prepare("select 1 from transcript_items where session_id = ? limit 1")
              .get(row.subject_id) !== undefined
          if (!hasTranscript) projectChatEvent(sqlite, event)
        }
      })()
      checkpoint(rows.length)
    }

    const sessions = sqlite.prepare("select id from sessions order by id").all() as ReadonlyArray<{
      id: string
    }>
    for (const session of sessions) {
      sqlite.transaction(() => {
        const hasChat =
          sqlite
            .prepare("select 1 from chat_items where session_id = ? limit 1")
            .get(session.id) !== undefined
        if (!hasChat) {
          const rows = sqlite
            .prepare(
              `select * from conversation_items where session_id = ?
               order by created_at asc, rowid asc`
            )
            .all(session.id) as ReadonlyArray<ConversationRow>
          for (const row of rows) {
            const attachments = parseAttachments(row.attachments)
            createChatItem(sqlite, session.id, row.role, row.created_at, {
              text: row.text,
              status: row.is_generating === 1 ? "streaming" : "complete",
              ...(attachments === undefined ? {} : { attachments })
            })
          }
        }
        chatState(sqlite, session.id)
      })()
      checkpoint(1)
    }

    const missingTranscript = Number(
      (
        sqlite
          .prepare(
            `select count(*) as count from transcript_items
             left join chat_items on chat_items.id = transcript_items.id
             where chat_items.id is null`
          )
          .get() as { count: number }
      ).count
    )
    const missingEvents = Number(
      (
        sqlite
          .prepare(
            `select count(*) as count from events
             join sessions on sessions.id = events.subject_id
             left join session_events on session_events.global_event_id = events.id
             where session_events.global_event_id is null`
          )
          .get() as { count: number }
      ).count
    )
    const mismatchedTranscript = Number(
      (
        sqlite
          .prepare(
            `select count(*) as count from transcript_items legacy
             join chat_items item on item.id = legacy.id
             left join chat_parts text_part
               on text_part.item_id = item.id and text_part.kind = 'text'
             left join chat_parts plan_part
               on plan_part.item_id = item.id and plan_part.kind = 'plan'
             where item.session_id != legacy.session_id
                or item.position != legacy.sequence
                or item.role != legacy.role
                or coalesce(text_part.text, '') != legacy.text
                or coalesce(plan_part.text, '') != coalesce(legacy.plan_document, '')
                or coalesce(item.attachments, '') != coalesce(legacy.attachments, '')`
          )
          .get() as { count: number }
      ).count
    )
    if (missingTranscript !== 0 || missingEvents !== 0 || mismatchedTranscript !== 0) {
      throw new Error(
        `Canonical chat verification failed: ${missingTranscript} transcript items missing, ${mismatchedTranscript} differ, and ${missingEvents} session events are missing`
      )
    }

    sqlite
      .prepare(
        `update backfill_jobs set state = 'completed', completed = total, error = null,
         updated_at = ? where id = ?`
      )
      .run(isoTimestamp(), canonicalChatBackfillId)
    completed = total
    progress("completed")
  } catch (cause) {
    /* v8 ignore next -- SQLite and explicit verification failures are Error instances. */
    const message = cause instanceof Error ? cause.message : String(cause)
    sqlite
      .prepare("update backfill_jobs set state = 'failed', error = ?, updated_at = ? where id = ?")
      .run(message, isoTimestamp(), canonicalChatBackfillId)
    progress("failed", message)
    throw cause
  }
}

/// Ordered registry for blocking, resumable data-version changes. Future
/// breaking upgrades add one runner here; schema creation still happens in
/// `migrations`, while the runner owns bounded commits, validation, progress,
/// and its durable `backfill_jobs` checkpoint.
const blockingDataUpgrades: ReadonlyArray<
  (sqlite: Database.Database, config: CodevisorDatabaseConfig) => void
> = [runCanonicalChatBackfill]

const runBlockingDataUpgrades = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): void => {
  for (const upgrade of blockingDataUpgrades) upgrade(sqlite, config)
}

const isSessionShellEvent = (kind: EventKind, payload: unknown): boolean => {
  if (kind === "session.created" || kind === "session.archived" || kind === "session.deleted") {
    return true
  }
  if (kind !== "session.updated") return false
  const value = jsonRecord(payload)
  // Metadata updates carry the full SessionSummary. Turn/config/stream state
  // remains exclusively in the session log.
  return typeof value?.id === "string" && typeof value.projectId === "string"
}

export interface CodevisorDatabaseService {
  readonly migrate: Effect.Effect<ReadonlyArray<string>, DatabaseError>
  readonly close: Effect.Effect<void>
  readonly createProject: (request: CreateProjectRequest) => Effect.Effect<Project, DatabaseError>
  readonly listProjects: Effect.Effect<ReadonlyArray<Project>, DatabaseError>
  readonly updateProject: (
    id: string,
    request: UpdateProjectRequest
  ) => Effect.Effect<Project, DatabaseError>
  readonly deleteProject: (id: string) => Effect.Effect<void, DatabaseError>
  readonly createWorktree: (
    projectId: string,
    name: string,
    branch: string,
    id?: string
  ) => Effect.Effect<Worktree, DatabaseError>
  readonly listWorktrees: (
    projectId: string
  ) => Effect.Effect<ReadonlyArray<Worktree>, DatabaseError>
  readonly deleteWorktree: (id: string) => Effect.Effect<void, DatabaseError>
  readonly listWorkspaces: Effect.Effect<ReadonlyArray<Workspace>, DatabaseError>
  readonly upsertWorkspace: (
    request: UpsertWorkspaceRequest
  ) => Effect.Effect<Workspace, DatabaseError>
  readonly deleteWorkspace: (id: string) => Effect.Effect<void, DatabaseError>
  readonly getWorkspaceNotes: (
    workspaceId: string
  ) => Effect.Effect<WorkspaceNotes | undefined, DatabaseError>
  readonly saveWorkspaceNotes: (
    request: UpsertWorkspaceNotesRequest & { readonly workspaceId: string }
  ) => Effect.Effect<WorkspaceNotes, DatabaseError>
  readonly setSessionWorkspace: (
    sessionId: string,
    workspaceId: string | null
  ) => Effect.Effect<void, DatabaseError>
  readonly createSession: (
    request: CreateSessionRequest
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly listSessions: Effect.Effect<ReadonlyArray<SessionSummary>, DatabaseError>
  readonly getSessionSummary: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  readonly getSessionConfigSelections: (
    id: string
  ) => Effect.Effect<Readonly<Record<string, string>>, DatabaseError>
  readonly getSessionDetail: (id: string) => Effect.Effect<SessionDetail, DatabaseError>
  readonly getTranscriptPage: (
    sessionId: string,
    before: number | undefined,
    limit: number
  ) => Effect.Effect<TranscriptPage, DatabaseError>
  readonly getTranscriptItemDetails: (
    sessionId: string,
    itemId: string
  ) => Effect.Effect<TranscriptItemDetails | undefined, DatabaseError>
  readonly updateSession: (
    id: string,
    request: UpdateSessionRequest
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly replaceSessionConfigSelections: (
    id: string,
    selections: Readonly<Record<string, string>>
  ) => Effect.Effect<void, DatabaseError>
  readonly updateSessionTitleFromHarness: (
    id: string,
    title: string
  ) => Effect.Effect<SessionSummary | undefined, DatabaseError>
  readonly archiveSession: (id: string) => Effect.Effect<SessionSummary, DatabaseError>
  readonly deleteSession: (id: string) => Effect.Effect<void, DatabaseError>
  readonly appendConversationItem: (
    sessionId: string,
    role: "user" | "assistant" | "system",
    messageId: string | undefined,
    text: string,
    isGenerating: boolean,
    attachments?: ReadonlyArray<AttachmentRef>
  ) => Effect.Effect<void, DatabaseError>
  readonly appendEvent: (
    kind: EventKind,
    subjectId: string,
    payload: unknown
  ) => Effect.Effect<EventEnvelope, DatabaseError>
  readonly listEvents: (since: number) => Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>
  readonly listSubjectEvents: (
    subjectId: string,
    since?: number
  ) => Effect.Effect<ReadonlyArray<EventEnvelope>, DatabaseError>
  readonly createPromptQueueItem: (
    sessionId: string,
    text: string,
    attachments?: ReadonlyArray<AttachmentRef>,
    id?: string
  ) => Effect.Effect<PromptQueueItem, DatabaseError>
  readonly createFile: (
    name: string,
    mimeType: string,
    kind: AttachmentKind,
    data: Buffer
  ) => Effect.Effect<FileMetadata, DatabaseError>
  readonly getFileMetadata: (id: string) => Effect.Effect<FileMetadata | undefined, DatabaseError>
  readonly getFile: (
    id: string
  ) => Effect.Effect<{ metadata: FileMetadata; data: Buffer } | undefined, DatabaseError>
  readonly listPromptQueue: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly updatePromptQueueItem: (
    sessionId: string,
    queueItemId: string,
    text: string
  ) => Effect.Effect<PromptQueueItem, DatabaseError>
  readonly deletePromptQueueItem: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly claimPromptQueueItem: (
    sessionId: string
  ) => Effect.Effect<PromptQueueItem | undefined, DatabaseError>
  readonly completePromptQueueItem: (
    sessionId: string,
    queueItemId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly listProcessingPromptQueue: (
    sessionId: string
  ) => Effect.Effect<ReadonlyArray<PromptQueueItem>, DatabaseError>
  readonly hasConversationMessage: (
    sessionId: string,
    messageId: string
  ) => Effect.Effect<boolean, DatabaseError>
  readonly hasTerminalAssistantAfterMessage: (
    sessionId: string,
    messageId: string
  ) => Effect.Effect<boolean, DatabaseError>
  /// Marks every still-streaming assistant chat item as failed except
  /// `excludeItemId`. Streaming rows are process-owned: whenever no live turn
  /// exists for them (server startup, crash recovery), they can never emit
  /// again and would otherwise render as an endless in-progress turn.
  readonly failStaleAssistantChatItems: (
    sessionId: string,
    stopDetail: string,
    excludeItemId?: string
  ) => Effect.Effect<number, DatabaseError>
  readonly getSessionActionResult: (
    sessionId: string,
    clientActionId: string
  ) => Effect.Effect<unknown | undefined, DatabaseError>
  readonly saveSessionActionResult: (
    sessionId: string,
    clientActionId: string,
    actionKind: string,
    response: unknown
  ) => Effect.Effect<void, DatabaseError>
  readonly setHarnessEnabled: (
    harnessId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly applyHarnessSettings: (
    harnesses: ReadonlyArray<Harness>
  ) => Effect.Effect<ReadonlyArray<Harness>, DatabaseError>
  readonly listMcpServers: Effect.Effect<ReadonlyArray<McpServerRecord>, DatabaseError>
  readonly getMcpServer: (id: string) => Effect.Effect<McpServerRecord | undefined, DatabaseError>
  readonly saveMcpServer: (
    request: SaveMcpServerRecordRequest
  ) => Effect.Effect<McpServerRecord, DatabaseError>
  readonly deleteMcpServer: (id: string) => Effect.Effect<void, DatabaseError>
  readonly setProjectMcpEnabled: (
    projectId: string,
    mcpServerId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly setSessionMcpEnabled: (
    sessionId: string,
    mcpServerId: string,
    enabled: boolean
  ) => Effect.Effect<void, DatabaseError>
  readonly resolveMcpServers: (
    projectId?: string,
    sessionId?: string
  ) => Effect.Effect<ReadonlyArray<McpServerRecord>, DatabaseError>
  readonly getNativeConfigBackup: (
    filePath: string
  ) => Effect.Effect<NativeConfigBackupRecord | undefined, DatabaseError>
  readonly saveNativeConfigBackup: (
    record: NativeConfigBackupRecord
  ) => Effect.Effect<void, DatabaseError>
  readonly saveNativeMcpRemoval: (
    request: SaveNativeMcpRemovalRequest
  ) => Effect.Effect<NativeMcpRemovalRecord, DatabaseError>
  readonly listNativeMcpRemovals: (
    includeRestored?: boolean
  ) => Effect.Effect<ReadonlyArray<NativeMcpRemovalRecord>, DatabaseError>
  readonly markNativeMcpRemovalRestored: (id: string) => Effect.Effect<void, DatabaseError>
  readonly listHarnessAccounts: (
    harnessId: string
  ) => Effect.Effect<ReadonlyArray<HarnessAccountRecord>, DatabaseError>
  readonly getHarnessAccount: (
    accountId: string
  ) => Effect.Effect<HarnessAccountRecord | undefined, DatabaseError>
  readonly saveHarnessAccount: (
    request: SaveHarnessAccountRequest
  ) => Effect.Effect<HarnessAccountRecord, DatabaseError>
  readonly updateHarnessAccountAuth: (
    accountId: string,
    request: UpdateHarnessAccountAuthRequest
  ) => Effect.Effect<HarnessAccountRecord, DatabaseError>
  readonly setActiveHarnessAccount: (
    harnessId: string,
    accountId: string
  ) => Effect.Effect<void, DatabaseError>
  readonly removeHarnessAccount: (accountId: string) => Effect.Effect<void, DatabaseError>
  readonly bindSessionHarnessAccount: (
    sessionId: string,
    accountId: string
  ) => Effect.Effect<SessionSummary, DatabaseError>
  readonly issuePairingToken: Effect.Effect<string, DatabaseError>
  readonly verifyBearerToken: (token: string) => Effect.Effect<boolean, DatabaseError>
  /// A stable machine identity that survives --serverId defaults ("local") and
  /// renames: generated once on first access and persisted with the database.
  readonly getOrCreateInstanceId: Effect.Effect<string, DatabaseError>
  /// The machine's stable connection token: generated once, persisted, and
  /// returned unchanged across restarts and updates until rotated. This is
  /// what `codevisor token` prints and `codevisor setup` hands to clients.
  readonly getOrCreateConnectionToken: Effect.Effect<string, DatabaseError>
  /// Replaces the connection token with a fresh one and retires the old,
  /// forcing previously paired clients to re-pair.
  readonly rotateConnectionToken: Effect.Effect<string, DatabaseError>
  readonly getUpdateInfo: Effect.Effect<UpdateInfo, DatabaseError>
  readonly setUpdateInfo: (update: UpdateInfo) => Effect.Effect<UpdateInfo, DatabaseError>
  /// Persisted latest-version knowledge per harness (the periodic update
  /// check's output — survives restarts so clients see last-known state).
  readonly listHarnessUpdateStates: Effect.Effect<
    ReadonlyArray<HarnessUpdateStateRecord>,
    DatabaseError
  >
  readonly setHarnessUpdateState: (
    record: HarnessUpdateStateRecord
  ) => Effect.Effect<HarnessUpdateStateRecord, DatabaseError>
  /// Durable pending/running update per harness (the when-idle gate's truth).
  readonly listHarnessPendingUpdates: Effect.Effect<
    ReadonlyArray<HarnessPendingUpdateRecord>,
    DatabaseError
  >
  readonly setHarnessPendingUpdate: (
    record: HarnessPendingUpdateRecord
  ) => Effect.Effect<HarnessPendingUpdateRecord, DatabaseError>
  readonly clearHarnessPendingUpdate: (harnessId: string) => Effect.Effect<void, DatabaseError>
}

export class CodevisorDatabase extends Context.Service<
  CodevisorDatabase,
  CodevisorDatabaseService
>()("@codevisor/db/CodevisorDatabase") {
  static readonly layer = (
    config: CodevisorDatabaseConfig
  ): Layer.Layer<CodevisorDatabase, DatabaseError> =>
    Layer.effect(
      CodevisorDatabase,
      Effect.map(makeDatabase(config), (service) => CodevisorDatabase.of(service))
    )
}

export const makeDatabase = (
  config: CodevisorDatabaseConfig
): Effect.Effect<CodevisorDatabaseService, DatabaseError> =>
  Effect.gen(function* () {
    const sqlite = yield* attempt("open", () => new Database(config.filename))
    sqlite.pragma("foreign_keys = ON")
    sqlite.pragma("journal_mode = WAL")
    const service = createService(sqlite, config)
    yield* service.migrate
    return service
  })

const createService = (
  sqlite: Database.Database,
  config: CodevisorDatabaseConfig
): CodevisorDatabaseService => {
  const migrate = attempt("migrate", () => {
    sqlite.exec(
      "create table if not exists schema_migrations (id integer primary key, name text not null)"
    )
    const applied = new Set(
      sqlite
        .prepare("select id from schema_migrations")
        .all()
        .map((row) => (row as { readonly id: number }).id)
    )
    const names: Array<string> = []
    // Table rebuilds (drop + rename) would cascade-delete child rows under enforced foreign
    // keys, and `pragma foreign_keys` is a no-op inside a transaction — toggle it out here.
    sqlite.pragma("foreign_keys = OFF")
    try {
      const transaction = sqlite.transaction(() => {
        for (const migration of migrations) {
          if (applied.has(migration.id)) {
            continue
          }
          sqlite.exec(migration.sql)
          migration.run?.(sqlite, config)
          sqlite
            .prepare("insert into schema_migrations (id, name) values (?, ?)")
            .run(migration.id, migration.name)
          names.push(migration.name)
        }
        sqlite
          .prepare(
            `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, '0.1.0', '0.1.0', 0, 'development', null, 'idle')
            on conflict(id) do nothing`
          )
          .run()
        const violations = sqlite.pragma("foreign_key_check") as ReadonlyArray<unknown>
        if (violations.length > 0) {
          throw new Error(`Migration left foreign key violations: ${JSON.stringify(violations)}`)
        }
      })
      transaction()
      // Required data upgrades run in bounded, checkpointed transactions
      // after the schema commit. Startup remains blocking, but the old tables
      // stay untouched and an interrupted process resumes from durable rows.
      runBlockingDataUpgrades(sqlite, config)
    } finally {
      sqlite.pragma("foreign_keys = ON")
    }
    return names
  })

  const harnessAccountRows = (harnessId: string): ReadonlyArray<HarnessAccountRow> =>
    sqlite
      .prepare(
        `select a.*,
                case when s.account_id = a.id then 1 else 0 end as is_active
         from harness_accounts a
         left join harness_account_selection s on s.harness_id = a.harness_id
         where a.harness_id = ? and a.removed_at is null
         order by is_active desc, a.created_at asc`
      )
      .all(harnessId) as ReadonlyArray<HarnessAccountRow>

  const requiredHarnessAccount = (accountId: string): HarnessAccountRecord => {
    const row = sqlite
      .prepare(
        `select a.*,
                case when s.account_id = a.id then 1 else 0 end as is_active
         from harness_accounts a
         left join harness_account_selection s on s.harness_id = a.harness_id
         where a.id = ? and a.removed_at is null`
      )
      .get(accountId) as HarnessAccountRow | undefined
    if (row === undefined) throw new Error(`Harness account not found: ${accountId}`)
    return harnessAccountFromRow(row)
  }

  const appendEvent = Effect.fn("CodevisorDatabase.appendEvent")(function* (
    kind: EventKind,
    subjectId: string,
    payload: unknown
  ) {
    return yield* attempt("appendEvent", () => {
      const createdAt = isoTimestamp()
      return sqlite.transaction(() => {
        const encoded = JSON.stringify(payload)
        const sessionExists =
          sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
        const belongsInShellLog = !sessionExists || isSessionShellEvent(kind, payload)
        const globalEventId = belongsInShellLog
          ? Number(
              sqlite
                .prepare(
                  "insert into events (server_id, kind, subject_id, created_at, payload) values (?, ?, ?, ?, ?)"
                )
                .run(config.serverId, kind, subjectId, createdAt, encoded).lastInsertRowid
            )
          : undefined
        let subjectRevision: number | undefined
        if (sessionExists) {
          const sessionEvent = insertSessionEvent(sqlite, {
            session_id: subjectId,
            global_event_id: globalEventId ?? null,
            server_id: config.serverId,
            kind,
            created_at: createdAt,
            payload: encoded
          })
          subjectRevision = sessionEvent.revision
          projectChatEvent(sqlite, sessionEvent)
          if (kind === "session.output") {
            sqlite
              .prepare("update sessions set updated_at = ? where id = ?")
              .run(createdAt, subjectId)
          }
        }
        return {
          id: (globalEventId ?? subjectRevision)!,
          ...(globalEventId === undefined ? {} : { globalEventId }),
          ...(subjectRevision === undefined ? {} : { subjectRevision }),
          serverId: config.serverId,
          kind,
          subjectId,
          createdAt,
          payload
        }
      })()
    })
  })

  const locationRowsFor = (projectId: string): ReadonlyArray<ProjectLocationRow> =>
    sqlite
      .prepare("select * from project_locations where project_id = ? order by created_at asc")
      .all(projectId) as ReadonlyArray<ProjectLocationRow>

  const localLocationFor = (projectId: string): ProjectLocationRow | undefined =>
    sqlite
      .prepare("select * from project_locations where project_id = ? and server_id = ?")
      .get(projectId, config.serverId) as ProjectLocationRow | undefined

  const getProject = (id: string): Project => {
    // Case-insensitive: UUID identifiers may arrive in either case. Use the
    // stored id (row.id) for the location lookup so it matches exactly.
    const row = sqlite.prepare("select * from projects where id = ? collate nocase").get(id) as
      | ProjectRow
      | undefined
    if (row === undefined) {
      throw new Error(`Project not found: ${id}`)
    }
    return projectFromRow(row, locationRowsFor(row.id))
  }

  const getSession = (id: string): SessionSummary => {
    const row = sqlite.prepare("select * from sessions where id = ?").get(id) as
      | SessionRow
      | undefined
    if (row === undefined) {
      throw new Error(`Session not found: ${id}`)
    }
    return sessionFromRow(row, localLocationFor(row.project_id)?.folder_path)
  }

  const createProject = Effect.fn("CodevisorDatabase.createProject")(function* (
    request: CreateProjectRequest
  ) {
    return yield* attempt("createProject", () => {
      const now = isoTimestamp()
      // UUIDs are case-insensitive identifiers. Canonicalize to lowercase on
      // write so ids stay consistent no matter which client created them
      // (Swift uppercases, Node lowercases) — a case-only difference must not
      // spawn a duplicate project or merge one into a differently-cased row.
      const projectId = (request.id ?? randomUUID()).toLowerCase()
      const createdAt = request.createdAt ?? now

      // Idempotency: re-creating an existing project id returns it.
      const byId = sqlite
        .prepare("select id from projects where id = ? collate nocase")
        .get(projectId) as { id: string } | undefined
      if (byId !== undefined) {
        return getProject(byId.id)
      }

      // A folder maps to exactly one project per server. If this folder is
      // already claimed under a different project id (stale data, another
      // client), merge that project into the requested id instead of failing
      // on the unique(server_id, folder_path) constraint — its sessions and
      // worktrees come along.
      const claimed = sqlite
        .prepare("select project_id from project_locations where server_id = ? and folder_path = ?")
        .get(config.serverId, request.folderPath) as { project_id: string } | undefined
      if (claimed !== undefined) {
        if (request.id === undefined || claimed.project_id.toLowerCase() === projectId) {
          return getProject(claimed.project_id)
        }
        const merge = sqlite.transaction(() => {
          sqlite
            .prepare(
              `insert into projects (
                id, name, is_archived, symbol_name, origin, created_at, repo_url
              ) values (?, ?, ?, ?, ?, ?, ?)`
            )
            .run(
              projectId,
              request.name ?? basename(request.folderPath),
              (request.isArchived ?? false) ? 1 : 0,
              request.symbolName ?? "folder.fill",
              request.origin ?? "codevisor",
              createdAt,
              request.repoUrl ?? null
            )
          for (const table of ["project_locations", "sessions", "worktrees"]) {
            sqlite
              .prepare(`update ${table} set project_id = ? where project_id = ?`)
              .run(projectId, claimed.project_id)
          }
          sqlite.prepare("delete from projects where id = ?").run(claimed.project_id)
        })
        merge()
        return getProject(projectId)
      }
      const location: ProjectLocation = {
        id: randomUUID(),
        projectId,
        serverId: config.serverId,
        folderPath: request.folderPath,
        createdAt
      }
      const project: Project = {
        id: projectId,
        name: request.name ?? basename(request.folderPath),
        isArchived: request.isArchived ?? false,
        symbolName: request.symbolName ?? "folder.fill",
        origin: request.origin ?? "codevisor",
        createdAt,
        locations: [location],
        ...(request.repoUrl === undefined ? {} : { repoUrl: request.repoUrl })
      }
      const transaction = sqlite.transaction(() => {
        sqlite
          .prepare(
            `insert into projects (
              id, name, is_archived, symbol_name, origin, created_at, repo_url
            ) values (?, ?, ?, ?, ?, ?, ?)`
          )
          .run(
            project.id,
            project.name,
            project.isArchived ? 1 : 0,
            project.symbolName,
            project.origin,
            project.createdAt,
            project.repoUrl ?? null
          )
        sqlite
          .prepare(
            `insert into project_locations (
              id, project_id, server_id, folder_path, created_at
            ) values (?, ?, ?, ?, ?)`
          )
          .run(
            location.id,
            location.projectId,
            location.serverId,
            location.folderPath,
            location.createdAt
          )
      })
      transaction()
      return project
    })
  })

  const createSession = Effect.fn("CodevisorDatabase.createSession")(function* (
    request: CreateSessionRequest
  ) {
    return yield* attempt("createSession", () => {
      const now = isoTimestamp()
      const id = request.id ?? randomUUID()
      sqlite
        .prepare(
          `insert into sessions (
            id, project_id, server_id, harness_id, harness_account_id, agent_session_id,
            title, origin, is_archived, worktree_name, workspace_id, created_at, updated_at
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
        )
        .run(
          id,
          request.projectId,
          config.serverId,
          request.harnessId,
          request.harnessAccountId ?? null,
          request.agentSessionId ?? null,
          request.title ?? "New Session",
          request.origin ?? "codevisor",
          (request.isArchived ?? false) ? 1 : 0,
          request.worktreeName ?? null,
          request.workspaceId ?? null,
          request.createdAt ?? now,
          request.updatedAt ?? null
        )
      return getSession(id)
    })
  })

  return {
    migrate,
    close: Effect.sync(() => sqlite.close()),
    createProject,
    listProjects: attempt("listProjects", () =>
      sqlite
        .prepare("select * from projects order by created_at desc")
        .all()
        .map((row) => projectFromRow(row as ProjectRow, locationRowsFor((row as ProjectRow).id)))
    ),
    updateProject: (id, request) =>
      attempt("updateProject", () => {
        const current = getProject(id)
        const updated: Project = {
          ...current,
          name: request.name ?? current.name,
          isArchived: request.isArchived ?? current.isArchived,
          symbolName: request.symbolName ?? current.symbolName
        }
        sqlite
          .prepare(
            "update projects set name = ?, is_archived = ?, symbol_name = ? where id = ? collate nocase"
          )
          .run(updated.name, updated.isArchived ? 1 : 0, updated.symbolName, id)
        return updated
      }),
    deleteProject: (id) =>
      attempt("deleteProject", () => {
        const result = sqlite.prepare("delete from projects where id = ? collate nocase").run(id)
        if (result.changes === 0) {
          throw new Error(`Project not found: ${id}`)
        }
      }),
    createWorktree: (projectId, name, branch, id) =>
      attempt("createWorktree", () => {
        getProject(projectId)
        const worktree: Worktree = {
          id: id ?? randomUUID(),
          projectId,
          serverId: config.serverId,
          name,
          branch,
          path: worktreePath(projectId, name),
          createdAt: isoTimestamp()
        }
        sqlite
          .prepare(
            `insert into worktrees (
              id, project_id, server_id, name, branch, created_at
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(worktree.id, projectId, worktree.serverId, name, branch, worktree.createdAt)
        return worktree
      }),
    listWorktrees: (projectId) =>
      attempt("listWorktrees", () =>
        (
          sqlite
            .prepare("select * from worktrees where project_id = ? order by created_at asc")
            .all(projectId) as ReadonlyArray<WorktreeRow>
        ).map(worktreeFromRow)
      ),
    deleteWorktree: (id) =>
      attempt("deleteWorktree", () => {
        sqlite.prepare("delete from worktrees where id = ?").run(id)
      }),
    listWorkspaces: attempt("listWorkspaces", () =>
      (
        sqlite
          .prepare("select * from workspaces order by created_at desc")
          .all() as ReadonlyArray<WorkspaceRow>
      ).map(workspaceFromRow)
    ),
    upsertWorkspace: (request) =>
      attempt("upsertWorkspace", () => {
        getProject(request.projectId)
        const now = isoTimestamp()
        const id = request.id ?? randomUUID()
        sqlite
          .prepare(
            `insert into workspaces (
               id, server_id, project_id, name, has_custom_name, symbol_name,
               root_directory, is_archived, created_at, updated_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, null)
             on conflict(id) do update set
               project_id = excluded.project_id,
               name = excluded.name,
               has_custom_name = excluded.has_custom_name,
               symbol_name = excluded.symbol_name,
               root_directory = excluded.root_directory,
               is_archived = excluded.is_archived,
               updated_at = ?`
          )
          .run(
            id,
            config.serverId,
            request.projectId,
            request.name,
            request.hasCustomName ? 1 : 0,
            request.symbolName ?? null,
            request.rootDirectory ?? null,
            (request.isArchived ?? false) ? 1 : 0,
            request.createdAt ?? now,
            now
          )
        return workspaceFromRow(
          sqlite.prepare("select * from workspaces where id = ?").get(id) as WorkspaceRow
        )
      }),
    deleteWorkspace: (id) =>
      attempt("deleteWorkspace", () => {
        const result = sqlite.prepare("delete from workspaces where id = ?").run(id)
        if (result.changes === 0) {
          throw new Error(`Workspace not found: ${id}`)
        }
      }),
    getWorkspaceNotes: (workspaceId) =>
      attempt("getWorkspaceNotes", () => {
        const row = sqlite
          .prepare("select * from workspace_notes where workspace_id = ?")
          .get(workspaceId) as WorkspaceNotesRow | undefined
        return row === undefined ? undefined : workspaceNotesFromRow(row)
      }),
    saveWorkspaceNotes: (request) =>
      attempt("saveWorkspaceNotes", () => {
        const workspace = sqlite
          .prepare("select id from workspaces where id = ?")
          .get(request.workspaceId) as { id: string } | undefined
        if (workspace === undefined) {
          throw new Error(`Workspace not found: ${request.workspaceId}`)
        }
        // Last write wins at the row level: the newest save replaces the
        // whole scratchpad, keeping the client's own edit stamp when sent.
        sqlite
          .prepare(
            `insert into workspace_notes (workspace_id, content, format, updated_at)
             values (?, ?, ?, ?)
             on conflict(workspace_id) do update set
               content = excluded.content,
               format = excluded.format,
               updated_at = excluded.updated_at`
          )
          .run(
            request.workspaceId,
            request.content,
            request.format ?? "attributed-string-v1",
            request.updatedAt ?? isoTimestamp()
          )
        return workspaceNotesFromRow(
          sqlite
            .prepare("select * from workspace_notes where workspace_id = ?")
            .get(request.workspaceId) as WorkspaceNotesRow
        )
      }),
    setSessionWorkspace: (sessionId, workspaceId) =>
      attempt("setSessionWorkspace", () => {
        const result = sqlite
          .prepare("update sessions set workspace_id = ? where id = ?")
          .run(workspaceId, sessionId)
        if (result.changes === 0) {
          throw new Error(`Session not found: ${sessionId}`)
        }
      }),
    createSession,
    listSessions: attempt("listSessions", () =>
      sqlite
        .prepare("select * from sessions order by coalesce(updated_at, created_at) desc")
        .all()
        .map((row) =>
          sessionFromRow(
            row as SessionRow,
            localLocationFor((row as SessionRow).project_id)?.folder_path
          )
        )
    ),
    getSessionSummary: (id) => attempt("getSessionSummary", () => getSession(id)),
    getSessionDetail: (id) =>
      attempt("getSessionDetail", () => {
        const session = getSession(id)
        const state = sqlite
          .prepare(
            "select revision as cursor, pending_question, background_tasks from sessions where id = ?"
          )
          .get(id) as {
          readonly cursor: number
          readonly pending_question: string | null
          readonly background_tasks: string
        }
        const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
        const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
        const goal = sessionGoalSnapshot(sqlite, id)
        return {
          session,
          conversation: sqlite
            .prepare(
              `select chat_items.id, chat_items.role, chat_items.message_id,
                 coalesce((select text from chat_parts
                   where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
                 chat_items.created_at, case when chat_items.status = 'streaming' then 1 else 0 end as is_generating,
                 chat_items.attachments
               from chat_items where session_id = ? order by position asc`
            )
            .all(id)
            .map((row) => conversationFromRow(row as ConversationRow)),
          promptQueue: listPromptQueueSync(sqlite, id),
          eventCursor: Number(state.cursor),
          ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
          backgroundTasks,
          ...(goal === undefined ? {} : { goal })
        }
      }),
    getTranscriptPage: (sessionId, before, limit) =>
      attempt("getTranscriptPage", () => {
        const session = getSession(sessionId)
        const bounded = Math.max(1, Math.min(64, Math.trunc(limit)))
        const rows = sqlite
          .prepare(
            `select chat_items.*,
               coalesce((select text from chat_parts
                 where item_id = chat_items.id and kind = 'text' order by position limit 1), '') as text,
               (select text from chat_parts
                 where item_id = chat_items.id and kind = 'plan' order by position limit 1) as plan_document
             from chat_items
             where session_id = ? and role in ('user', 'assistant')
               and (? is null or position < ?)
             order by position desc limit ?`
          )
          .all(sessionId, before ?? null, before ?? null, bounded + 1) as ReadonlyArray<ChatItemRow>
        const candidates = rows.slice(0, bounded)
        const pageRows: ChatItemRow[] = []
        let characters = 0
        const maxCharacters =
          bounded <= 8 ? maxInitialTranscriptPageCharacters : maxOlderTranscriptPageCharacters
        for (const row of candidates) {
          const rowCharacters = row.text.length + (row.plan_document?.length ?? 0)
          if (pageRows.length > 0 && characters + rowCharacters > maxCharacters) {
            break
          }
          pageRows.push(row)
          characters += rowCharacters
        }
        const hasMore = rows.length > pageRows.length
        const items = [...pageRows].reverse().map((row) => {
          const item = transcriptFromChatRow(row)
          if (row.role !== "assistant" || row.status !== "streaming") return item
          const summary = chatAssistantSummary(sqlite, sessionId, row.id)
          return {
            ...item,
            text: summary.text,
            ...(summary.planDocument === undefined ? {} : { planDocument: summary.planDocument }),
            ...(summary.messageId === undefined ? {} : { messageId: summary.messageId })
          }
        })
        const cursor = pageRows.at(-1)?.position
        const state = sqlite
          .prepare(
            "select revision as cursor, pending_question, background_tasks from sessions where id = ?"
          )
          .get(sessionId) as {
          readonly cursor: number
          readonly pending_question: string | null
          readonly background_tasks: string
        }
        const pendingQuestion = pendingQuestionFromRaw(state.pending_question)
        const backgroundTasks = backgroundTasksFromRaw(state.background_tasks)
        const goal = sessionGoalSnapshot(sqlite, sessionId)
        return {
          items,
          ...(hasMore ? { nextBefore: String(cursor!) } : {}),
          hasMore,
          eventCursor: Number(state.cursor),
          ...(pendingQuestion === undefined ? {} : { pendingQuestion }),
          backgroundTasks,
          ...(goal === undefined ? {} : { goal }),
          usage: session.usage
        }
      }),
    getTranscriptItemDetails: (sessionId, itemId) =>
      attempt("getTranscriptItemDetails", () => {
        const item = sqlite
          .prepare("select revision from chat_items where session_id = ? and id = ?")
          .get(sessionId, itemId) as { revision: number } | undefined
        if (item === undefined) return undefined
        const events = (
          sqlite
            .prepare(
              `select * from session_events
               where session_id = ? and chat_item_id = ? order by revision asc`
            )
            .all(sessionId, itemId) as ReadonlyArray<SessionEventRow>
        ).map(sessionEventFromRow)
        return { itemId, revision: item.revision, events }
      }),
    getSessionConfigSelections: (id) =>
      attempt("getSessionConfigSelections", () => {
        const row = sqlite
          .prepare("select config_selections from sessions where id = ?")
          .get(id) as { readonly config_selections: string } | undefined
        if (row === undefined) throw new Error(`Session not found: ${id}`)
        return sessionConfigSelectionsFromRaw(row.config_selections)
      }),
    // Metadata updates deliberately leave updated_at alone: recency ordering
    // tracks conversation activity (chat events stamp it as items
    // land, the last being the finished assistant response), so opening or
    // renaming a session must not reshuffle the sidebar.
    updateSession: (id, request) =>
      attempt("updateSession", () => {
        const current = getSession(id)
        sqlite
          .prepare(
            `update sessions set
              title = ?,
              title_is_user_set = case
                when ? is not null and ? <> title then 1
                else title_is_user_set
              end,
              is_archived = ?, agent_session_id = ?, worktree_name = ?,
              harness_id = ?, harness_account_id = ?, updated_at = ?
             where id = ?`
          )
          .run(
            request.title ?? current.title,
            request.title ?? null,
            request.title ?? null,
            (request.isArchived ?? current.isArchived) ? 1 : 0,
            request.agentSessionId ?? current.agentSessionId ?? null,
            request.worktreeName ?? current.worktreeName ?? null,
            request.harnessId ?? current.harnessId,
            request.harnessAccountId ?? current.harnessAccountId ?? null,
            request.updatedAt ?? current.updatedAt ?? null,
            id
          )
        return getSession(id)
      }),
    replaceSessionConfigSelections: (id, selections) =>
      attempt("replaceSessionConfigSelections", () => {
        getSession(id)
        sqlite
          .prepare("update sessions set config_selections = ? where id = ?")
          .run(JSON.stringify(selections), id)
      }),
    // This condition lives in the UPDATE itself so a user rename and a
    // harness title arriving concurrently cannot pass a stale read/check.
    updateSessionTitleFromHarness: (id, title) =>
      attempt("updateSessionTitleFromHarness", () => {
        const result = sqlite
          .prepare(
            `update sessions set title = ?
             where id = ? and title_is_user_set = 0 and title <> ?`
          )
          .run(title, id, title)
        if (result.changes === 0) {
          // Preserve updateSession's missing-id behavior while returning no
          // value for protected and idempotent title updates.
          getSession(id)
          return undefined
        }
        return getSession(id)
      }),
    archiveSession: (id) =>
      attempt("archiveSession", () => {
        sqlite.prepare("update sessions set is_archived = 1 where id = ?").run(id)
        return getSession(id)
      }),
    deleteSession: (id) =>
      attempt("deleteSession", () => {
        sqlite.prepare("delete from sessions where id = ?").run(id)
      }),
    appendConversationItem: (sessionId, role, messageId, text, isGenerating, attachments) =>
      attempt("appendConversationItem", () => {
        const now = isoTimestamp()
        // Streamed messages arrive as token-sized chunks sharing a messageId.
        // Extend the newest item in place when the chunk continues it —
        // materializing one row per token grew a single answer into
        // thousands of rows, bloating the store and making session opens
        // replay-heavy. Coalescing needs a provable same-span signal, so
        // rows without a messageId (and attachment-bearing rows) still
        // insert normally.
        sqlite.transaction(() => {
          const routeKey = messageId === undefined ? undefined : `message:${role}:${messageId}`
          const routed = routeKey === undefined ? undefined : chatRoute(sqlite, sessionId, routeKey)
          const last = sqlite
            .prepare(
              "select id from chat_items where session_id = ? order by position desc limit 1"
            )
            .get(sessionId) as { id: string } | undefined
          if (
            routed !== undefined &&
            routed === last?.id &&
            (attachments === undefined || attachments.length === 0)
          ) {
            sqlite
              .prepare(
                `update chat_parts set text = coalesce(text, '') || ?, revision = revision + 1
                 where item_id = ? and kind = 'text'`
              )
              .run(text, routed)
            sqlite
              .prepare(
                "update chat_items set status = ?, updated_at = ?, revision = revision + 1 where id = ?"
              )
              .run(isGenerating ? "streaming" : "complete", now, routed)
          } else {
            const itemId = createChatItem(sqlite, sessionId, role, now, {
              text,
              ...(messageId === undefined ? {} : { messageId }),
              status: isGenerating ? "streaming" : "complete",
              ...(attachments === undefined ? {} : { attachments })
            })
            if (routeKey !== undefined && (attachments === undefined || attachments.length === 0)) {
              setChatRoute(sqlite, sessionId, routeKey, itemId)
            }
          }
          sqlite.prepare("update sessions set updated_at = ? where id = ?").run(now, sessionId)
        })()
      }),
    appendEvent,
    listEvents: (since) =>
      attempt("listEvents", () =>
        sqlite
          .prepare("select * from events where id > ? order by id asc")
          .all(since)
          .map((row) => eventFromRow(row as EventRow))
      ),
    listSubjectEvents: (subjectId, since = 0) =>
      attempt("listSubjectEvents", () => {
        const isSession =
          sqlite.prepare("select 1 from sessions where id = ?").get(subjectId) !== undefined
        return isSession
          ? sqlite
              .prepare(
                `select * from session_events
                 where session_id = ? and revision > ? order by revision asc`
              )
              .all(subjectId, since)
              .map((row) => sessionEventFromRow(row as SessionEventRow))
          : sqlite
              .prepare("select * from events where subject_id = ? and id > ? order by id asc")
              .all(subjectId, since)
              .map((row) => eventFromRow(row as EventRow))
      }),
    createPromptQueueItem: (sessionId, text, attachments, id) =>
      attempt("createPromptQueueItem", () => {
        getSession(sessionId)
        const now = isoTimestamp()
        const item: PromptQueueItem = {
          // A client-supplied id makes the eventual user-echo messageId the
          // client's own optimistic-message id (identity reconciliation).
          id: id ?? randomUUID(),
          sessionId,
          text,
          createdAt: now,
          updatedAt: now,
          ...(attachments === undefined || attachments.length === 0 ? {} : { attachments })
        }
        sqlite
          .prepare(
            `insert into prompt_queue_items (
              id, session_id, text, created_at, updated_at, attachments
            ) values (?, ?, ?, ?, ?, ?)`
          )
          .run(item.id, sessionId, text, now, now, serializeAttachments(attachments))
        return item
      }),
    createFile: (name, mimeType, kind, data) =>
      attempt("createFile", () => {
        const metadata: FileMetadata = {
          id: randomUUID(),
          name,
          mimeType,
          sizeBytes: data.byteLength,
          sha256: createHash("sha256").update(data).digest("hex"),
          kind,
          createdAt: isoTimestamp()
        }
        sqlite
          .prepare(
            `insert into files (
              id, name, mime_type, size_bytes, sha256, kind, created_at, data
            ) values (?, ?, ?, ?, ?, ?, ?, ?)`
          )
          .run(
            metadata.id,
            metadata.name,
            metadata.mimeType,
            metadata.sizeBytes,
            metadata.sha256,
            metadata.kind,
            metadata.createdAt,
            data
          )
        return metadata
      }),
    getFileMetadata: (id) =>
      attempt("getFileMetadata", () => {
        const row = sqlite
          .prepare(
            "select id, name, mime_type, size_bytes, sha256, kind, created_at from files where id = ?"
          )
          .get(id) as FileRow | undefined
        return row === undefined ? undefined : fileMetadataFromRow(row)
      }),
    getFile: (id) =>
      attempt("getFile", () => {
        const row = sqlite.prepare("select * from files where id = ?").get(id) as
          | (FileRow & { readonly data: Buffer })
          | undefined
        return row === undefined
          ? undefined
          : { metadata: fileMetadataFromRow(row), data: row.data }
      }),
    listPromptQueue: (sessionId) =>
      attempt("listPromptQueue", () => {
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId)
      }),
    updatePromptQueueItem: (sessionId, queueItemId, text) =>
      attempt("updatePromptQueueItem", () => {
        const now = isoTimestamp()
        const result = sqlite
          .prepare(
            "update prompt_queue_items set text = ?, updated_at = ? where session_id = ? and id = ?"
          )
          .run(text, now, sessionId, queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
        return promptQueueFromRow(
          sqlite
            .prepare("select * from prompt_queue_items where session_id = ? and id = ?")
            .get(sessionId, queueItemId) as PromptQueueRow
        )
      }),
    deletePromptQueueItem: (sessionId, queueItemId) =>
      attempt("deletePromptQueueItem", () => {
        const result = sqlite
          .prepare("delete from prompt_queue_items where session_id = ? and id = ?")
          .run(sessionId, queueItemId)
        if (result.changes === 0) {
          throw new Error(`Prompt queue item not found: ${queueItemId}`)
        }
      }),
    claimPromptQueueItem: (sessionId) =>
      attempt("claimPromptQueueItem", () => {
        const transaction = sqlite.transaction(() => {
          const row = sqlite
            .prepare(
              `select * from prompt_queue_items
               where session_id = ? and state = 'pending'
               order by created_at asc, rowid asc
               limit 1`
            )
            .get(sessionId) as PromptQueueRow | undefined
          if (row === undefined) {
            return undefined
          }
          sqlite
            .prepare("update prompt_queue_items set state = 'processing' where id = ?")
            .run(row.id)
          return promptQueueFromRow(row)
        })
        return transaction()
      }),
    completePromptQueueItem: (sessionId, queueItemId) =>
      attempt("completePromptQueueItem", () => {
        sqlite
          .prepare(
            "delete from prompt_queue_items where session_id = ? and id = ? and state = 'processing'"
          )
          .run(sessionId, queueItemId)
      }),
    listProcessingPromptQueue: (sessionId) =>
      attempt("listProcessingPromptQueue", () => {
        getSession(sessionId)
        return listPromptQueueSync(sqlite, sessionId, "processing")
      }),
    hasConversationMessage: (sessionId, messageId) =>
      attempt("hasConversationMessage", () =>
        Boolean(
          sqlite
            .prepare("select 1 from chat_items where session_id = ? and message_id = ? limit 1")
            .get(sessionId, messageId)
        )
      ),
    hasTerminalAssistantAfterMessage: (sessionId, messageId) =>
      attempt("hasTerminalAssistantAfterMessage", () =>
        Boolean(
          sqlite
            .prepare(
              `select 1
               from chat_items as input
               join chat_items as answer
                 on answer.session_id = input.session_id
                and answer.position > input.position
                and answer.role = 'assistant'
                and answer.status != 'streaming'
               where input.session_id = ? and input.message_id = ?
               limit 1`
            )
            .get(sessionId, messageId)
        )
      ),
    failStaleAssistantChatItems: (sessionId, stopDetail, excludeItemId) =>
      attempt("failStaleAssistantChatItems", () => {
        getSession(sessionId)
        return sqlite.transaction(() => {
          const stale = sqlite
            .prepare(
              `select id from chat_items
               where session_id = ? and role = 'assistant' and status = 'streaming' and id != ?
               order by position asc`
            )
            .all(sessionId, excludeItemId ?? "") as Array<{ id: string }>
          const now = isoTimestamp()
          for (const row of stale) {
            finishAssistantChatItem(sqlite, sessionId, row.id, now, "interrupted", stopDetail, false, true)
          }
          // A failed row can never be the projection's write target again; a
          // pointer left on one would resurrect it on the next assistant event.
          sqlite
            .prepare(
              `update session_chat_state set current_item_id = null
               where session_id = ? and current_item_id in (
                 select id from chat_items where session_id = ? and status = 'failed'
               )`
            )
            .run(sessionId, sessionId)
          return stale.length
        })()
      }),
    getSessionActionResult: (sessionId, clientActionId) =>
      attempt("getSessionActionResult", () => {
        const row = sqlite
          .prepare("select * from session_actions where session_id = ? and client_action_id = ?")
          .get(sessionId, clientActionId) as SessionActionRow | undefined
        return row === undefined ? undefined : (JSON.parse(row.response) as unknown)
      }),
    saveSessionActionResult: (sessionId, clientActionId, actionKind, response) =>
      attempt("saveSessionActionResult", () => {
        sqlite
          .prepare(
            `insert into session_actions (
              session_id, client_action_id, action_kind, response, created_at
            ) values (?, ?, ?, ?, ?)
            on conflict(session_id, client_action_id) do nothing`
          )
          .run(sessionId, clientActionId, actionKind, JSON.stringify(response), isoTimestamp())
      }),
    setHarnessEnabled: (harnessId, enabled) =>
      attempt("setHarnessEnabled", () => {
        sqlite
          .prepare(
            `insert into harness_settings (harness_id, enabled) values (?, ?)
             on conflict(harness_id) do update set enabled = excluded.enabled`
          )
          .run(harnessId, enabled ? 1 : 0)
      }),
    applyHarnessSettings: (harnesses) =>
      attempt("applyHarnessSettings", () => {
        const disabled = new Set(
          sqlite
            .prepare("select harness_id from harness_settings where enabled = 0")
            .all()
            .map((row) => (row as { readonly harness_id: string }).harness_id)
        )
        return harnesses.map((harness) => ({ ...harness, enabled: !disabled.has(harness.id) }))
      }),
    listMcpServers: attempt("listMcpServers", () =>
      (
        sqlite
          .prepare("select * from mcp_servers order by name collate nocase")
          .all() as ReadonlyArray<McpServerRow>
      ).map(mcpServerFromRow)
    ),
    getMcpServer: (id) =>
      attempt("getMcpServer", () => {
        const row = sqlite.prepare("select * from mcp_servers where id = ?").get(id) as
          | McpServerRow
          | undefined
        return row === undefined ? undefined : mcpServerFromRow(row)
      }),
    saveMcpServer: (request) =>
      attempt("saveMcpServer", () => {
        const id = request.id ?? randomUUID()
        const now = isoTimestamp()
        sqlite
          .prepare(
            `insert into mcp_servers (
               id, name, transport, url, command, args, enabled, auth_type, oauth_scope,
               connection_state, tool_count, detail, secret_cipher, created_at, updated_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               name = excluded.name, transport = excluded.transport, url = excluded.url,
               command = excluded.command, args = excluded.args, enabled = excluded.enabled,
               auth_type = excluded.auth_type, oauth_scope = excluded.oauth_scope,
               connection_state = excluded.connection_state, tool_count = excluded.tool_count,
               detail = excluded.detail, secret_cipher = excluded.secret_cipher,
               updated_at = excluded.updated_at`
          )
          .run(
            id,
            request.name,
            request.transport,
            request.url ?? null,
            request.command ?? null,
            JSON.stringify(request.args ?? []),
            request.enabled ? 1 : 0,
            request.authType,
            request.oauthScope ?? null,
            request.connectionState,
            request.toolCount,
            request.detail ?? null,
            request.secretCipher ?? null,
            now,
            now
          )
        return mcpServerFromRow(
          sqlite.prepare("select * from mcp_servers where id = ?").get(id) as McpServerRow
        )
      }),
    deleteMcpServer: (id) =>
      attempt("deleteMcpServer", () => {
        sqlite.prepare("delete from mcp_servers where id = ?").run(id)
      }),
    setProjectMcpEnabled: (projectId, mcpServerId, enabled) =>
      attempt("setProjectMcpEnabled", () => {
        sqlite
          .prepare(
            `insert into project_mcp_settings (project_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(project_id, mcp_server_id) do update set enabled = excluded.enabled`
          )
          .run(projectId, mcpServerId, enabled ? 1 : 0)
      }),
    setSessionMcpEnabled: (sessionId, mcpServerId, enabled) =>
      attempt("setSessionMcpEnabled", () => {
        sqlite
          .prepare(
            `insert into session_mcp_settings (session_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(session_id, mcp_server_id) do update set enabled = excluded.enabled`
          )
          .run(sessionId, mcpServerId, enabled ? 1 : 0)
      }),
    resolveMcpServers: (projectId, sessionId) =>
      attempt("resolveMcpServers", () => {
        const projectSettings =
          projectId === undefined
            ? new Map<string, boolean>()
            : new Map(
                (
                  sqlite
                    .prepare(
                      "select mcp_server_id, enabled from project_mcp_settings where project_id = ?"
                    )
                    .all(projectId) as ReadonlyArray<{ mcp_server_id: string; enabled: number }>
                ).map((row) => [row.mcp_server_id, row.enabled === 1] as const)
              )
        const sessionSettings =
          sessionId === undefined
            ? new Map<string, boolean>()
            : new Map(
                (
                  sqlite
                    .prepare(
                      "select mcp_server_id, enabled from session_mcp_settings where session_id = ?"
                    )
                    .all(sessionId) as ReadonlyArray<{ mcp_server_id: string; enabled: number }>
                ).map((row) => [row.mcp_server_id, row.enabled === 1] as const)
              )
        return (
          sqlite
            .prepare("select * from mcp_servers order by name collate nocase")
            .all() as ReadonlyArray<McpServerRow>
        )
          .map(mcpServerFromRow)
          .map((server) => ({
            ...server,
            enabled:
              server.enabled &&
              projectSettings.get(server.id) !== false &&
              sessionSettings.get(server.id) !== false
          }))
      }),
    getNativeConfigBackup: (filePath) =>
      attempt("getNativeConfigBackup", () => {
        const row = sqlite
          .prepare("select * from native_config_backups where file_path = ?")
          .get(filePath) as NativeConfigBackupRow | undefined
        return row === undefined
          ? undefined
          : { backupPath: row.backup_path, createdAt: row.created_at, filePath: row.file_path }
      }),
    saveNativeConfigBackup: (record) =>
      attempt("saveNativeConfigBackup", () => {
        // First write wins: the backup captures the file before Codevisor
        // ever touched it and must never be replaced by a later state.
        sqlite
          .prepare(
            `insert into native_config_backups (file_path, backup_path, created_at)
             values (?, ?, ?) on conflict(file_path) do nothing`
          )
          .run(record.filePath, record.backupPath, record.createdAt)
      }),
    saveNativeMcpRemoval: (request) =>
      attempt("saveNativeMcpRemoval", () => {
        const id = randomUUID()
        const now = isoTimestamp()
        sqlite
          .prepare(
            `insert into native_mcp_removals
               (id, harness_id, config_path, server_name, fragment, removed_at)
             values (?, ?, ?, ?, ?, ?)`
          )
          .run(id, request.harnessId, request.configPath, request.serverName, request.fragment, now)
        return nativeMcpRemovalFromRow(
          sqlite
            .prepare("select * from native_mcp_removals where id = ?")
            .get(id) as NativeMcpRemovalRow
        )
      }),
    listNativeMcpRemovals: (includeRestored) =>
      attempt("listNativeMcpRemovals", () =>
        (
          sqlite
            .prepare(
              includeRestored === true
                ? "select * from native_mcp_removals order by removed_at desc"
                : "select * from native_mcp_removals where restored_at is null order by removed_at desc"
            )
            .all() as ReadonlyArray<NativeMcpRemovalRow>
        ).map(nativeMcpRemovalFromRow)
      ),
    markNativeMcpRemovalRestored: (id) =>
      attempt("markNativeMcpRemovalRestored", () => {
        sqlite
          .prepare("update native_mcp_removals set restored_at = ? where id = ?")
          .run(isoTimestamp(), id)
      }),
    listHarnessAccounts: (harnessId) =>
      attempt("listHarnessAccounts", () =>
        harnessAccountRows(harnessId).map(harnessAccountFromRow)
      ),
    getHarnessAccount: (accountId) =>
      attempt("getHarnessAccount", () => {
        const row = sqlite
          .prepare(
            `select a.*,
                    case when s.account_id = a.id then 1 else 0 end as is_active
             from harness_accounts a
             left join harness_account_selection s on s.harness_id = a.harness_id
             where a.id = ? and a.removed_at is null`
          )
          .get(accountId) as HarnessAccountRow | undefined
        return row === undefined ? undefined : harnessAccountFromRow(row)
      }),
    saveHarnessAccount: (request) =>
      attempt("saveHarnessAccount", () => {
        const now = isoTimestamp()
        const existing =
          request.profileKind === "default"
            ? (sqlite
                .prepare(
                  "select id from harness_accounts where harness_id = ? and profile_kind = 'default' and removed_at is null"
                )
                .get(request.harnessId) as { readonly id: string } | undefined)
            : request.profileKey === undefined
              ? undefined
              : (sqlite
                  .prepare(
                    "select id from harness_accounts where harness_id = ? and profile_key = ? and removed_at is null"
                  )
                  .get(request.harnessId, request.profileKey) as
                  | { readonly id: string }
                  | undefined)
        const id = existing?.id ?? request.id ?? randomUUID()
        sqlite
          .prepare(
            `insert into harness_accounts (
               id, harness_id, profile_kind, profile_key, label, email, organization_id,
               auth_method, auth_state, can_login, can_logout, last_checked_at, detail,
               created_at, updated_at, removed_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, null)
             on conflict(id) do update set
               label = excluded.label,
               email = excluded.email,
               organization_id = excluded.organization_id,
               auth_method = excluded.auth_method,
               auth_state = excluded.auth_state,
               can_login = excluded.can_login,
               can_logout = excluded.can_logout,
               last_checked_at = excluded.last_checked_at,
               detail = excluded.detail,
               updated_at = excluded.updated_at,
               removed_at = null`
          )
          .run(
            id,
            request.harnessId,
            request.profileKind,
            request.profileKey ?? null,
            request.label,
            request.email ?? null,
            request.organizationId ?? null,
            request.authMethod ?? null,
            request.authState,
            request.canLogin ? 1 : 0,
            request.canLogout ? 1 : 0,
            request.lastCheckedAt ?? null,
            request.detail ?? null,
            now,
            now
          )
        const selected = sqlite
          .prepare("select account_id from harness_account_selection where harness_id = ?")
          .get(request.harnessId) as { readonly account_id: string } | undefined
        if (selected === undefined) {
          sqlite
            .prepare("insert into harness_account_selection (harness_id, account_id) values (?, ?)")
            .run(request.harnessId, id)
        }
        return requiredHarnessAccount(id)
      }),
    updateHarnessAccountAuth: (accountId, request) =>
      attempt("updateHarnessAccountAuth", () => {
        const current = requiredHarnessAccount(accountId)
        sqlite
          .prepare(
            `update harness_accounts set
               label = ?, email = ?, organization_id = ?, auth_method = ?, auth_state = ?,
               can_login = ?, can_logout = ?, last_checked_at = ?, detail = ?, updated_at = ?
             where id = ? and removed_at is null`
          )
          .run(
            request.label ?? current.label,
            request.email === undefined ? (current.email ?? null) : request.email,
            request.organizationId === undefined
              ? (current.organizationId ?? null)
              : request.organizationId,
            request.authMethod === undefined ? (current.authMethod ?? null) : request.authMethod,
            request.authState,
            (request.canLogin ?? current.canLogin) ? 1 : 0,
            (request.canLogout ?? current.canLogout) ? 1 : 0,
            request.lastCheckedAt ?? isoTimestamp(),
            request.detail === undefined ? (current.detail ?? null) : request.detail,
            isoTimestamp(),
            accountId
          )
        return requiredHarnessAccount(accountId)
      }),
    setActiveHarnessAccount: (harnessId, accountId) =>
      attempt("setActiveHarnessAccount", () => {
        const account = requiredHarnessAccount(accountId)
        if (account.harnessId !== harnessId) throw new Error("Account belongs to another harness")
        sqlite
          .prepare(
            `insert into harness_account_selection (harness_id, account_id) values (?, ?)
             on conflict(harness_id) do update set account_id = excluded.account_id`
          )
          .run(harnessId, accountId)
      }),
    removeHarnessAccount: (accountId) =>
      attempt("removeHarnessAccount", () => {
        const account = requiredHarnessAccount(accountId)
        if (account.profileKind === "default") {
          throw new Error("The default harness profile cannot be removed")
        }
        const inUse = sqlite
          .prepare("select id from sessions where harness_account_id = ? limit 1")
          .get(accountId)
        if (inUse !== undefined) throw new Error("Account is used by an existing session")
        sqlite.prepare("delete from harness_account_selection where account_id = ?").run(accountId)
        sqlite
          .prepare("update harness_accounts set removed_at = ?, updated_at = ? where id = ?")
          .run(isoTimestamp(), isoTimestamp(), accountId)
      }),
    bindSessionHarnessAccount: (sessionId, accountId) =>
      attempt("bindSessionHarnessAccount", () => {
        requiredHarnessAccount(accountId)
        sqlite
          .prepare("update sessions set harness_account_id = ? where id = ?")
          .run(accountId, sessionId)
        return getSession(sessionId)
      }),
    issuePairingToken: attempt("issuePairingToken", () => {
      const token = `hm_${randomBytes(24).toString("base64url")}`
      sqlite
        .prepare("insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)")
        .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      return token
    }),
    verifyBearerToken: (token) =>
      attempt("verifyBearerToken", () => {
        const row = sqlite
          .prepare("select id from auth_tokens where token_hash = ?")
          .get(hashToken(token))
        return row !== undefined
      }),
    getOrCreateInstanceId: attempt("getOrCreateInstanceId", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'machine-id'")
        .get() as { readonly value: string } | undefined
      if (row !== undefined) return row.value
      const id = randomUUID()
      sqlite.prepare("insert into instance_meta (key, value) values ('machine-id', ?)").run(id)
      return id
    }),
    getOrCreateConnectionToken: attempt("getOrCreateConnectionToken", () => {
      const row = sqlite
        .prepare("select value from instance_meta where key = 'connection-token'")
        .get() as { readonly value: string } | undefined
      if (row !== undefined) return row.value
      // Stable across restarts and updates: the plaintext lives in
      // instance_meta so it can be shown again, and its hash goes in
      // auth_tokens so verifyBearerToken accepts it like any pairing token.
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const create = sqlite.transaction(() => {
        sqlite
          .prepare("insert into instance_meta (key, value) values ('connection-token', ?)")
          .run(token)
        sqlite
          .prepare(
            "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)"
          )
          .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      })
      create()
      return token
    }),
    rotateConnectionToken: attempt("rotateConnectionToken", () => {
      const existing = sqlite
        .prepare("select value from instance_meta where key = 'connection-token'")
        .get() as { readonly value: string } | undefined
      const token = `hm_${randomBytes(24).toString("base64url")}`
      const rotate = sqlite.transaction(() => {
        if (existing !== undefined) {
          // Retire the old token so previously paired clients must re-pair.
          sqlite
            .prepare("delete from auth_tokens where token_hash = ?")
            .run(hashToken(existing.value))
        }
        sqlite
          .prepare(
            `insert into instance_meta (key, value) values ('connection-token', ?)
             on conflict(key) do update set value = excluded.value`
          )
          .run(token)
        sqlite
          .prepare(
            "insert into auth_tokens (id, token_hash, scope, created_at) values (?, ?, ?, ?)"
          )
          .run(randomUUID(), hashToken(token), "admin", isoTimestamp())
      })
      rotate()
      return token
    }),
    listHarnessPendingUpdates: attempt("listHarnessPendingUpdates", () =>
      (
        sqlite
          .prepare("select * from harness_pending_updates")
          .all() as Array<HarnessPendingUpdateRow>
      ).map(harnessPendingUpdateFromRow)
    ),
    setHarnessPendingUpdate: (record) =>
      attempt("setHarnessPendingUpdate", () => {
        sqlite
          .prepare(
            `insert into harness_pending_updates (
              harness_id, state, target_version, requested_at, started_at, timeout_at
            ) values (?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              state = excluded.state,
              target_version = excluded.target_version,
              requested_at = excluded.requested_at,
              started_at = excluded.started_at,
              timeout_at = excluded.timeout_at`
          )
          .run(
            record.harnessId,
            record.state,
            record.targetVersion ?? null,
            record.requestedAt,
            record.startedAt ?? null,
            record.timeoutAt ?? null
          )
        return record
      }),
    clearHarnessPendingUpdate: (harnessId) =>
      attempt("clearHarnessPendingUpdate", () => {
        sqlite.prepare("delete from harness_pending_updates where harness_id = ?").run(harnessId)
      }),
    listHarnessUpdateStates: attempt("listHarnessUpdateStates", () =>
      (
        sqlite.prepare("select * from harness_update_state").all() as Array<HarnessUpdateStateRow>
      ).map(harnessUpdateStateFromRow)
    ),
    setHarnessUpdateState: (record) =>
      attempt("setHarnessUpdateState", () => {
        sqlite
          .prepare(
            `insert into harness_update_state (
              harness_id, installed_version, latest_version, update_available,
              source, install_origin, channel, checked_at
            ) values (?, ?, ?, ?, ?, ?, ?, ?)
            on conflict(harness_id) do update set
              installed_version = excluded.installed_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              source = excluded.source,
              install_origin = excluded.install_origin,
              channel = excluded.channel,
              checked_at = excluded.checked_at`
          )
          .run(
            record.harnessId,
            record.info.installedVersion ?? null,
            record.info.latestVersion ?? null,
            record.info.updateAvailable ? 1 : 0,
            record.info.source ?? null,
            record.info.installOrigin ?? null,
            record.info.channel ?? null,
            record.info.checkedAt ?? null
          )
        return record
      }),
    getUpdateInfo: attempt("getUpdateInfo", () =>
      updateFromRow(sqlite.prepare("select * from update_state where id = 1").get() as UpdateRow)
    ),
    setUpdateInfo: (update) =>
      attempt("setUpdateInfo", () => {
        sqlite
          .prepare(
            `insert into update_state (
              id, current_version, latest_version, update_available, channel, checked_at, migration_state
            ) values (1, ?, ?, ?, ?, ?, ?)
            on conflict(id) do update set
              current_version = excluded.current_version,
              latest_version = excluded.latest_version,
              update_available = excluded.update_available,
              channel = excluded.channel,
              checked_at = excluded.checked_at,
              migration_state = excluded.migration_state`
          )
          .run(
            update.currentVersion,
            update.latestVersion,
            update.updateAvailable ? 1 : 0,
            update.channel,
            update.checkedAt ?? null,
            update.migrationState
          )
        return update
      })
  }
}

const attempt = <A>(operation: string, run: () => A): Effect.Effect<A, DatabaseError> =>
  Effect.try({
    try: run,
    catch: (cause) =>
      new DatabaseError({
        operation,
        /* v8 ignore next -- better-sqlite3 and Node filesystem failures arrive as Error instances. */
        message: cause instanceof Error ? cause.message : String(cause)
      })
  })

const basename = (path: string): string => path.split("/").filter(Boolean).at(-1) ?? path

const projectLocationFromRow = (row: ProjectLocationRow): ProjectLocation => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  folderPath: row.folder_path,
  createdAt: row.created_at
})

const projectFromRow = (
  row: ProjectRow,
  locations: ReadonlyArray<ProjectLocationRow>
): Project => ({
  id: row.id,
  name: row.name,
  isArchived: row.is_archived === 1,
  symbolName: row.symbol_name,
  origin: row.origin,
  createdAt: row.created_at,
  locations: locations.map(projectLocationFromRow),
  ...(row.repo_url === null ? {} : { repoUrl: row.repo_url })
})

const worktreeFromRow = (row: WorktreeRow): Worktree => ({
  id: row.id,
  projectId: row.project_id,
  serverId: row.server_id,
  name: row.name,
  branch: row.branch,
  path: worktreePath(row.project_id, row.name),
  createdAt: row.created_at
})

const workspaceFromRow = (row: WorkspaceRow): Workspace => ({
  id: row.id,
  serverId: row.server_id,
  projectId: row.project_id,
  name: row.name,
  hasCustomName: row.has_custom_name === 1,
  ...(row.symbol_name === null ? {} : { symbolName: row.symbol_name }),
  ...(row.root_directory === null ? {} : { rootDirectory: row.root_directory }),
  isArchived: row.is_archived === 1,
  createdAt: row.created_at,
  ...(row.updated_at === null ? {} : { updatedAt: row.updated_at })
})

const workspaceNotesFromRow = (row: WorkspaceNotesRow): WorkspaceNotes => ({
  workspaceId: row.workspace_id,
  content: row.content,
  format: row.format,
  updatedAt: row.updated_at
})

const sessionFromRow = (row: SessionRow, folderPath: string | undefined): SessionSummary => {
  const cwd = resolveSessionCwd(folderPath, row.project_id, row.worktree_name ?? undefined)
  return {
    id: row.id,
    projectId: row.project_id,
    serverId: row.server_id,
    harnessId: row.harness_id,
    ...(row.harness_account_id === null ? {} : { harnessAccountId: row.harness_account_id }),
    ...(row.agent_session_id === null ? {} : { agentSessionId: row.agent_session_id }),
    title: row.title,
    origin: row.origin,
    isArchived: row.is_archived === 1,
    ...(row.worktree_name === null ? {} : { worktreeName: row.worktree_name }),
    ...(row.workspace_id === null ? {} : { workspaceId: row.workspace_id }),
    ...(cwd === undefined ? {} : { cwd }),
    createdAt: row.created_at,
    ...(row.updated_at === null ? {} : { updatedAt: row.updated_at }),
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

const harnessAccountFromRow = (row: HarnessAccountRow): HarnessAccountRecord => ({
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

const serializeAttachments = (
  attachments: ReadonlyArray<AttachmentRef> | undefined
): string | null =>
  attachments === undefined || attachments.length === 0 ? null : JSON.stringify(attachments)

const parseAttachments = (raw: string | null): ReadonlyArray<AttachmentRef> | undefined => {
  if (raw === null) {
    return undefined
  }
  const parsed = JSON.parse(raw) as ReadonlyArray<AttachmentRef>
  return parsed.length === 0 ? undefined : parsed
}

const conversationFromRow = (row: ConversationRow): SessionDetail["conversation"][number] => {
  const attachments = parseAttachments(row.attachments)
  return {
    id: row.id,
    role: row.role,
    ...(row.message_id === null ? {} : { messageId: row.message_id }),
    text: row.text,
    createdAt: row.created_at,
    isGenerating: row.is_generating === 1,
    ...(attachments === undefined ? {} : { attachments })
  }
}

const transcriptFromChatRow = (row: ChatItemRow): TranscriptItem => {
  const attachments = parseAttachments(row.attachments)
  /* v8 ignore next 3 -- the query filters roles and chat_items enforces the same CHECK constraint. */
  if (row.role !== "user" && row.role !== "assistant") {
    throw new Error(`Unsupported transcript role: ${row.role}`)
  }
  return {
    id: row.id,
    sessionId: row.session_id,
    sequence: row.position,
    role: row.role,
    text: row.text,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    isGenerating: row.status === "streaming",
    hasDetails: row.has_details === 1,
    ...(row.turn_id === null ? {} : { turnId: row.turn_id }),
    ...(row.started_at === null ? {} : { startedAt: row.started_at }),
    ...(row.completed_at === null ? {} : { endedAt: row.completed_at }),
    ...(row.stop_reason === null ? {} : { stopReason: row.stop_reason }),
    ...(row.stop_detail === null ? {} : { stopDetail: row.stop_detail }),
    ...(row.retryable === 1 ? { retryable: true } : {}),
    ...(row.plan_document === null ? {} : { planDocument: row.plan_document }),
    ...(attachments === undefined ? {} : { attachments }),
    revision: row.revision
  }
}

const promptQueueFromRow = (row: PromptQueueRow): PromptQueueItem => {
  const attachments = parseAttachments(row.attachments)
  return {
    id: row.id,
    sessionId: row.session_id,
    text: row.text,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(attachments === undefined ? {} : { attachments })
  }
}

const fileMetadataFromRow = (row: FileRow): FileMetadata => ({
  id: row.id,
  name: row.name,
  mimeType: row.mime_type,
  sizeBytes: row.size_bytes,
  sha256: row.sha256,
  kind: row.kind,
  createdAt: row.created_at
})

const listPromptQueueSync = (
  sqlite: Database.Database,
  sessionId: string,
  state: PromptQueueRow["state"] = "pending"
): ReadonlyArray<PromptQueueItem> =>
  sqlite
    .prepare(
      `select * from prompt_queue_items
       where session_id = ? and state = ?
       order by created_at asc, rowid asc`
    )
    .all(sessionId, state)
    .map((row) => promptQueueFromRow(row as PromptQueueRow))

const eventFromRow = (row: EventRow): EventEnvelope => ({
  id: row.id,
  globalEventId: row.id,
  serverId: row.server_id,
  kind: row.kind,
  subjectId: row.subject_id,
  createdAt: row.created_at,
  payload: JSON.parse(row.payload) as unknown
})

const sessionEventFromRow = (row: SessionEventRow): EventEnvelope => ({
  id: row.revision,
  ...(row.global_event_id === null ? {} : { globalEventId: row.global_event_id }),
  subjectRevision: row.revision,
  serverId: row.server_id,
  kind: row.kind,
  subjectId: row.session_id,
  createdAt: row.created_at,
  payload: JSON.parse(row.payload) as unknown
})

const harnessPendingUpdateFromRow = (row: HarnessPendingUpdateRow): HarnessPendingUpdateRecord => ({
  harnessId: row.harness_id,
  requestedAt: row.requested_at,
  state: row.state,
  ...(row.target_version === null ? {} : { targetVersion: row.target_version }),
  ...(row.started_at === null ? {} : { startedAt: row.started_at }),
  ...(row.timeout_at === null ? {} : { timeoutAt: row.timeout_at })
})

const harnessUpdateStateFromRow = (row: HarnessUpdateStateRow): HarnessUpdateStateRecord => ({
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

const updateFromRow = (row: UpdateRow): UpdateInfo => ({
  currentVersion: row.current_version,
  latestVersion: row.latest_version,
  updateAvailable: row.update_available === 1,
  channel: row.channel,
  ...(row.checked_at === null ? {} : { checkedAt: row.checked_at }),
  migrationState: row.migration_state
})

const mcpServerFromRow = (row: McpServerRow): McpServerRecord => ({
  id: row.id,
  name: row.name,
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

interface NativeConfigBackupRow {
  readonly file_path: string
  readonly backup_path: string
  readonly created_at: string
}

interface NativeMcpRemovalRow {
  readonly id: string
  readonly harness_id: string
  readonly config_path: string
  readonly server_name: string
  readonly fragment: string
  readonly removed_at: string
  readonly restored_at: string | null
}

const nativeMcpRemovalFromRow = (row: NativeMcpRemovalRow): NativeMcpRemovalRecord => ({
  configPath: row.config_path,
  fragment: row.fragment,
  harnessId: row.harness_id,
  id: row.id,
  removedAt: row.removed_at,
  ...(row.restored_at === null ? {} : { restoredAt: row.restored_at }),
  serverName: row.server_name
})

const hashToken = (token: string): string => createHash("sha256").update(token).digest("hex")
