// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import type { CloudMachinePresence } from "@codevisor/api"

/// The hub's durable shape: per-hub SQLite migrations (append-only, applied
/// on wake — see user-hub.ts) and the row/attachment types they imply.

export const HUB_MIGRATIONS: readonly string[] = [
  `CREATE TABLE machines (
     device_id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     os TEXT,
     app_version TEXT,
     public_key TEXT NOT NULL,
     last_seen_at TEXT NOT NULL
   )`,
  // Resumable connection identities + their offline relay buffers (see
  // resume-sessions.ts). Grouped as one append-only step.
  `CREATE TABLE sessions (
     connection_id TEXT PRIMARY KEY,
     kind TEXT NOT NULL,
     device_id TEXT NOT NULL,
     public_key TEXT,
     resume_token_hash TEXT NOT NULL,
     expires_at INTEGER
   );
   CREATE UNIQUE INDEX sessions_token ON sessions (resume_token_hash);
   CREATE TABLE session_buffers (
     connection_id TEXT NOT NULL,
     seq INTEGER NOT NULL,
     message BLOB NOT NULL,
     PRIMARY KEY (connection_id, seq)
   )`
]

export interface MachineRow extends Record<string, SqlStorageValue> {
  device_id: string
  name: string
  os: string | null
  app_version: string | null
  public_key: string
  last_seen_at: string
}

export interface SocketAttachment {
  kind: "app" | "machine"
  connectionId: string
  /// Machine sockets: the registered device id. App sockets: absent until
  /// hello, then the app's self-assigned device id.
  deviceId?: string
  /// App sockets: static public key from hello, attached to `open` relays so
  /// machines can authenticate the channel opener.
  publicKey?: string
  helloDone: boolean
}

export const machineRows = (sql: SqlStorage): MachineRow[] =>
  sql.exec<MachineRow>("SELECT * FROM machines ORDER BY name, device_id").toArray()

export const machineRow = (sql: SqlStorage, deviceId: string): MachineRow | undefined =>
  sql.exec<MachineRow>("SELECT * FROM machines WHERE device_id = ?", deviceId).toArray()[0]

export const machinePresence = (row: MachineRow, online: boolean): CloudMachinePresence => ({
  deviceId: row.device_id,
  name: row.name,
  ...(row.os !== null ? { os: row.os } : {}),
  ...(row.app_version !== null ? { appVersion: row.app_version } : {}),
  publicKey: row.public_key,
  online,
  lastSeenAt: row.last_seen_at
})
