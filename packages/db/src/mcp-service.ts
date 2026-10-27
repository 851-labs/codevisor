import { randomUUID } from "node:crypto"

import { isoTimestamp } from "@codevisor/api"

import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { mcpServerFromRow, nativeMcpRemovalFromRow } from "./row-mappers.js"
import { integer, rowReader, text } from "./row-reader.js"
import { mcpServerRows, nativeConfigBackupRows, nativeMcpRemovalRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

const mcpSettingRows = rowReader({ mcp_server_id: text, enabled: integer })

const listMcpServerRows = (sqlite: ServiceContext["sqlite"]) =>
  mcpServerRows.all(sqlite.prepare(mcpServerSql.list).all()).map(mcpServerFromRow)

const readProjectMcpSettings = (
  sqlite: ServiceContext["sqlite"],
  projectId: string | undefined
): Map<string, boolean> => {
  if (projectId === undefined) return new Map<string, boolean>()
  return enabledByServer(sqlite, mcpSettingSql.byProject, projectId)
}

const readSessionMcpSettings = (
  sqlite: ServiceContext["sqlite"],
  sessionId: string | undefined
): Map<string, boolean> => {
  if (sessionId === undefined) return new Map<string, boolean>()
  return enabledByServer(sqlite, mcpSettingSql.bySession, sessionId)
}

const enabledByServer = (
  sqlite: ServiceContext["sqlite"],
  sql: string,
  rawOwnerId: string
): Map<string, boolean> =>
  new Map(
    mcpSettingRows
      .all(sqlite.prepare(sql).all(canonicalUuid(rawOwnerId)))
      .map((row) => [row.mcp_server_id, row.enabled === 1] as const)
  )

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
    listMcpServers: attempt("listMcpServers", () => listMcpServerRows(sqlite)),
    getMcpServer: (id) =>
      attempt("getMcpServer", () => {
        const row = mcpServerRow(sqlite, id)
        return row === undefined ? undefined : mcpServerFromRow(row)
      }),
    saveMcpServer: (request) =>
      attempt("saveMcpServer", () => {
        const id = request.id ?? randomUUID()
        const now = isoTimestamp()
        sqlite
          .prepare(mcpServerSql.upsert)
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
            request.catalogId ?? null,
            request.catalogVersion ?? null,
            request.capabilities === undefined ? null : JSON.stringify(request.capabilities),
            now,
            now
          )
        return mcpServerFromRow(savedMcpServerRow(sqlite, id))
      }),
    deleteMcpServer: (id) =>
      attempt("deleteMcpServer", () => {
        sqlite.prepare(mcpServerSql.delete).run(id)
      }),
    setProjectMcpEnabled: (projectId, mcpServerId, enabled) =>
      attempt("setProjectMcpEnabled", () => {
        sqlite
          .prepare(mcpSettingSql.setProject)
          .run(canonicalUuid(projectId), mcpServerId, enabled ? 1 : 0)
      }),
    setSessionMcpEnabled: (sessionId, mcpServerId, enabled) =>
      attempt("setSessionMcpEnabled", () => {
        sqlite
          .prepare(mcpSettingSql.setSession)
          .run(canonicalUuid(sessionId), mcpServerId, enabled ? 1 : 0)
      }),
    resolveMcpServers: (projectId, sessionId) =>
      attempt("resolveMcpServers", () => {
        const projectSettings = readProjectMcpSettings(sqlite, projectId)
        const sessionSettings = readSessionMcpSettings(sqlite, sessionId)
        return listMcpServerRows(sqlite).map((server) => ({
          ...server,
          enabled:
            server.enabled &&
            projectSettings.get(server.id) !== false &&
            sessionSettings.get(server.id) !== false
        }))
      }),
    getNativeConfigBackup: (filePath) =>
      attempt("getNativeConfigBackup", () => {
        const row = nativeConfigBackupRow(sqlite, filePath)
        return row === undefined
          ? undefined
          : { backupPath: row.backup_path, createdAt: row.created_at, filePath: row.file_path }
      }),
    saveNativeConfigBackup: (record) =>
      attempt("saveNativeConfigBackup", () => {
        sqlite
          .prepare(nativeConfigSql.insertBackup)
          .run(record.filePath, record.backupPath, record.createdAt)
      }),
    saveNativeMcpRemoval: (request) =>
      attempt("saveNativeMcpRemoval", () => {
        const id = randomUUID()
        const now = isoTimestamp()
        sqlite
          .prepare(nativeConfigSql.insertRemoval)
          .run(id, request.harnessId, request.configPath, request.serverName, request.fragment, now)
        return nativeMcpRemovalFromRow(savedNativeMcpRemovalRow(sqlite, id))
      }),
    listNativeMcpRemovals: () =>
      attempt("listNativeMcpRemovals", () =>
        unrestoredNativeMcpRemovals(sqlite).map(nativeMcpRemovalFromRow)
      ),
    markNativeMcpRemovalRestored: (id) =>
      attempt("markNativeMcpRemovalRestored", () => {
        sqlite.prepare(nativeConfigSql.markRemovalRestored).run(isoTimestamp(), id)
      })
  }
}

const mcpServerRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  mcpServerRows.maybe(sqlite.prepare(mcpServerSql.byId).get(id))

const savedMcpServerRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  mcpServerRows.one(sqlite.prepare(mcpServerSql.byId).get(id))

const nativeConfigBackupRow = (sqlite: ServiceContext["sqlite"], filePath: string) =>
  nativeConfigBackupRows.maybe(sqlite.prepare(nativeConfigSql.backupByPath).get(filePath))

const savedNativeMcpRemovalRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  nativeMcpRemovalRows.one(sqlite.prepare(nativeConfigSql.removalById).get(id))

const unrestoredNativeMcpRemovals = (sqlite: ServiceContext["sqlite"]) =>
  nativeMcpRemovalRows.all(sqlite.prepare(nativeConfigSql.unrestoredRemovals).all())

const mcpServerSql = {
  list: "select * from mcp_servers order by name collate nocase",
  byId: "select * from mcp_servers where id = ?",
  upsert: `insert into mcp_servers (
               id, name, kind, transport, url, command, args, enabled, auth_type, oauth_scope,
               connection_state, tool_count, detail, secret_cipher, catalog_id, catalog_version,
               capabilities, created_at, updated_at
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             on conflict(id) do update set
               name = excluded.name, kind = excluded.kind, transport = excluded.transport, url = excluded.url,
               command = excluded.command, args = excluded.args, enabled = excluded.enabled,
               auth_type = excluded.auth_type, oauth_scope = excluded.oauth_scope,
               connection_state = excluded.connection_state, tool_count = excluded.tool_count,
               detail = excluded.detail, secret_cipher = excluded.secret_cipher,
               catalog_id = excluded.catalog_id, catalog_version = excluded.catalog_version,
               capabilities = excluded.capabilities, updated_at = excluded.updated_at`,
  delete: "delete from mcp_servers where id = ?"
}

const mcpSettingSql = {
  byProject: "select mcp_server_id, enabled from project_mcp_settings where project_id = ?",
  bySession: "select mcp_server_id, enabled from session_mcp_settings where session_id = ?",
  setProject: `insert into project_mcp_settings (project_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(project_id, mcp_server_id) do update set enabled = excluded.enabled`,
  setSession: `insert into session_mcp_settings (session_id, mcp_server_id, enabled) values (?, ?, ?)
             on conflict(session_id, mcp_server_id) do update set enabled = excluded.enabled`
}

const nativeConfigSql = {
  backupByPath: "select * from native_config_backups where file_path = ?",
  insertBackup: `insert into native_config_backups (file_path, backup_path, created_at)
             values (?, ?, ?) on conflict(file_path) do nothing`,
  insertRemoval: `insert into native_mcp_removals
               (id, harness_id, config_path, server_name, fragment, removed_at)
             values (?, ?, ?, ?, ?, ?)`,
  removalById: "select * from native_mcp_removals where id = ?",
  unrestoredRemovals:
    "select * from native_mcp_removals where restored_at is null order by removed_at desc",
  markRemovalRestored: "update native_mcp_removals set restored_at = ? where id = ?"
}
