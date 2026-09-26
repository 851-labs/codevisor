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
   )`,
  // Socket attachments survive Durable Object hibernation and deploys. A
  // generation makes one machine socket authoritative when a replacement
  // overlaps the half-open predecessor it supersedes.
  `ALTER TABLE machines ADD COLUMN active_generation INTEGER NOT NULL DEFAULT 0`,
  // The machine's stable Codevisor server id (hello `device.serverId`), so
  // peers can match hub presence to the same machine reached directly; and
  // whether it accepts channels from other machines (MACHINE_PEERS_FEATURE).
  `ALTER TABLE machines ADD COLUMN server_id TEXT;
   ALTER TABLE machines ADD COLUMN peer_aware INTEGER NOT NULL DEFAULT 0`
]

export interface MachineRow extends Record<string, SqlStorageValue> {
  device_id: string
  name: string
  os: string | null
  app_version: string | null
  public_key: string
  last_seen_at: string
  active_generation: number
  server_id: string | null
  /// 1 when the last hello advertised MACHINE_PEERS_FEATURE.
  peer_aware: number
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
  /// Machine sockets that advertised MACHINE_PEERS_FEATURE: they receive the
  /// machine list, presence, and machine-reset, and may open channels to
  /// other machines on the account.
  peerAware?: boolean
  /// Machine sockets: the generation installed in the durable registry when
  /// this hello won ownership. Missing means generation 0 for sockets that
  /// survived deployment of the generation migration.
  machineGeneration?: number
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
  ...(row.server_id === null || row.server_id === undefined ? {} : { serverId: row.server_id }),
  ...(row.peer_aware === 1 ? { machinePeers: true } : {}),
  online,
  lastSeenAt: row.last_seen_at
})
