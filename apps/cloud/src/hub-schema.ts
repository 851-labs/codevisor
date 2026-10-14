import type { CloudMachinePresence } from "@codevisor/api"

import { machineTunnel } from "./hub-tunnel.js"

export const HUB_MIGRATIONS: readonly string[] = [
  `CREATE TABLE machines (
     device_id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     os TEXT,
     app_version TEXT,
     public_key TEXT NOT NULL,
     last_seen_at TEXT NOT NULL
   )`,
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
  `ALTER TABLE machines ADD COLUMN active_generation INTEGER NOT NULL DEFAULT 0`,
  `ALTER TABLE machines ADD COLUMN server_id TEXT;
   ALTER TABLE machines ADD COLUMN peer_aware INTEGER NOT NULL DEFAULT 0`,
  `ALTER TABLE machines ADD COLUMN tunnel_endpoint_id TEXT;
   ALTER TABLE machines ADD COLUMN tunnel_addr TEXT;
   CREATE TABLE app_devices (
     device_id TEXT PRIMARY KEY,
     public_key TEXT NOT NULL,
     endpoint_id TEXT NOT NULL,
     last_seen_at TEXT NOT NULL
   )`,
  `CREATE TABLE machine_origins (
     device_id TEXT PRIMARY KEY,
     added_by_device_id TEXT NOT NULL,
     added_by_name TEXT NOT NULL
   )`
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
  peer_aware: number
  tunnel_endpoint_id: string | null
  tunnel_addr: string | null
  added_by_device_id: string | null
  added_by_name: string | null
}

export interface SocketAttachment {
  kind: "app" | "machine"
  connectionId: string
  deviceId?: string
  publicKey?: string
  peerAware?: boolean
  machineGeneration?: number
  tunnel?: boolean
  helloDone: boolean
}

const MACHINE_SELECT = `SELECT machines.*, machine_origins.added_by_device_id,
    machine_origins.added_by_name
  FROM machines LEFT JOIN machine_origins USING (device_id)`

export const machineRows = (sql: SqlStorage): MachineRow[] =>
  sql.exec<MachineRow>(`${MACHINE_SELECT} ORDER BY name, device_id`).toArray()

export const machineRow = (sql: SqlStorage, deviceId: string): MachineRow | undefined =>
  sql.exec<MachineRow>(`${MACHINE_SELECT} WHERE device_id = ?`, deviceId).toArray()[0]

export const machinePresence = (row: MachineRow, online: boolean): CloudMachinePresence => {
  const tunnel = machineTunnel(row.tunnel_endpoint_id, row.tunnel_addr)
  return {
    deviceId: row.device_id,
    name: row.name,
    ...(row.os !== null ? { os: row.os } : {}),
    ...(row.app_version !== null ? { appVersion: row.app_version } : {}),
    publicKey: row.public_key,
    ...(row.server_id === null || row.server_id === undefined ? {} : { serverId: row.server_id }),
    ...(row.peer_aware === 1 ? { machinePeers: true } : {}),
    ...(tunnel === undefined ? {} : { tunnel }),
    ...(row.added_by_device_id == null || row.added_by_name == null
      ? {}
      : { addedBy: { deviceId: row.added_by_device_id, name: row.added_by_name } }),
    online,
    lastSeenAt: row.last_seen_at
  }
}
