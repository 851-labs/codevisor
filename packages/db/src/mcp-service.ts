import { isoTimestamp } from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { mcpServerFromRow, nativeMcpRemovalFromRow } from "./row-mappers.js"
import type { McpServerRow, NativeConfigBackupRow, NativeMcpRemovalRow } from "./rows.js"
import type { CodevisorDatabaseService } from "./service.js"
import type { ServiceContext } from "./service-context.js"

export const makeMcpService = (
  context: ServiceContext
): Pick<
  CodevisorDatabaseService,
  | "listMcpServers"
  | "getMcpServer"
  | "saveMcpServer"
  | "deleteMcpServer"
  | "setProjectMcpEnabled"
  | "setSessionMcpEnabled"
  | "resolveMcpServers"
  | "getNativeConfigBackup"
  | "saveNativeConfigBackup"
  | "saveNativeMcpRemoval"
  | "listNativeMcpRemovals"
  | "markNativeMcpRemovalRestored"
> => {
  const { sqlite } = context

  return {
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
               id, name, kind, transport, url, command, args, enabled, auth_type, oauth_scope,
               connection_state, tool_count, detail, secret_cipher, created_at, updated_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               name = excluded.name, kind = excluded.kind, transport = excluded.transport, url = excluded.url,
               command = excluded.command, args = excluded.args, enabled = excluded.enabled,
               auth_type = excluded.auth_type, oauth_scope = excluded.oauth_scope,
               connection_state = excluded.connection_state, tool_count = excluded.tool_count,
               detail = excluded.detail, secret_cipher = excluded.secret_cipher,
               updated_at = excluded.updated_at`
          )
          .run(
            id,
            request.name,
            request.kind ?? "managed",
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
          .run(canonicalUuid(projectId), mcpServerId, enabled ? 1 : 0)
      }),
    setSessionMcpEnabled: (sessionId, mcpServerId, enabled) =>
      attempt("setSessionMcpEnabled", () => {
        sqlite
          .prepare(
            `insert into session_mcp_settings (session_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(session_id, mcp_server_id) do update set enabled = excluded.enabled`
          )
          .run(canonicalUuid(sessionId), mcpServerId, enabled ? 1 : 0)
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
                    .all(canonicalUuid(projectId)) as ReadonlyArray<{
                    mcp_server_id: string
                    enabled: number
                  }>
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
                    .all(canonicalUuid(sessionId)) as ReadonlyArray<{
                    mcp_server_id: string
                    enabled: number
                  }>
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
      })
  }
}
