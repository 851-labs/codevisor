import type { CloudMachinePresence } from "@codevisor/api"
import { z } from "zod"

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
   )`,
  `ALTER TABLE machines ADD COLUMN display_name TEXT;
   ALTER TABLE machines ADD COLUMN icon TEXT;
   ALTER TABLE machines ADD COLUMN reported_icon TEXT`,
  `ALTER TABLE machine_origins ADD COLUMN ephemeral_provider TEXT`,
  `CREATE TABLE inbox_subscribers (
     inbox_id TEXT NOT NULL,
     device_id TEXT NOT NULL,
     PRIMARY KEY (inbox_id, device_id)
   );
   CREATE INDEX inbox_subscribers_device ON inbox_subscribers (device_id);
   CREATE TABLE inbox_rates (
     inbox_id TEXT PRIMARY KEY,
     window_start INTEGER NOT NULL,
     count INTEGER NOT NULL
   );
   CREATE TABLE device_queue (
     seq INTEGER PRIMARY KEY,
     device_id TEXT NOT NULL,
     item_id TEXT NOT NULL,
     inbox_id TEXT,
     frame TEXT NOT NULL,
     bytes INTEGER NOT NULL,
     expires_at INTEGER NOT NULL
   );
   CREATE UNIQUE INDEX device_queue_item ON device_queue (device_id, item_id);
   CREATE INDEX device_queue_inbox ON device_queue (inbox_id, device_id);
   CREATE INDEX device_queue_expiry ON device_queue (expires_at)`
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
  display_name: string | null
  icon: string | null
  reported_icon: string | null
  added_by_device_id: string | null
  added_by_name: string | null
  ephemeral_provider: string | null
}

export const SocketAttachment = z.object({
  kind: z.enum(["app", "machine"]),
  connectionId: z.string(),
  deviceId: z.string().exactOptional(),
  publicKey: z.string().exactOptional(),
  peerAware: z.boolean().exactOptional(),
  machineGeneration: z.number().exactOptional(),
  tunnel: z.boolean().exactOptional(),
  helloDone: z.boolean()
})
export type SocketAttachment = z.infer<typeof SocketAttachment>

export const machineRows = (sql: SqlStorage): MachineRow[] =>
  sql.exec<MachineRow>(machineSelectSql.all).toArray()

export const machineRow = (sql: SqlStorage, deviceId: string): MachineRow | undefined =>
  sql.exec<MachineRow>(machineSelectSql.byDeviceId, deviceId).toArray()[0]

export const machinePresence = (row: MachineRow, online: boolean): CloudMachinePresence => {
  const tunnel = machineTunnel(row.tunnel_endpoint_id, row.tunnel_addr)
  const icon = row.icon ?? row.reported_icon
  return {
    deviceId: row.device_id,
    name: row.display_name ?? row.name,
    ...(icon == null ? {} : { icon }),
    ...(row.os !== null ? { os: row.os } : {}),
    ...(row.app_version !== null ? { appVersion: row.app_version } : {}),
    publicKey: row.public_key,
    ...(row.server_id === null || row.server_id === undefined ? {} : { serverId: row.server_id }),
    ...(row.peer_aware === 1 ? { machinePeers: true } : {}),
    ...(tunnel === undefined ? {} : { tunnel }),
    ...(row.added_by_device_id == null || row.added_by_name == null
      ? {}
      : { addedBy: { deviceId: row.added_by_device_id, name: row.added_by_name } }),
    ...ephemeralOrigin(row),
    online,
    lastSeenAt: row.last_seen_at
  }
}

const ephemeralOrigin = (row: MachineRow): Pick<CloudMachinePresence, "ephemeral"> =>
  row.ephemeral_provider == null || row.added_by_device_id == null
    ? {}
    : { ephemeral: { provider: row.ephemeral_provider, ownerDeviceId: row.added_by_device_id } }

const MACHINE_SELECT = `SELECT machines.*, machine_origins.added_by_device_id,
    machine_origins.added_by_name, machine_origins.ephemeral_provider
  FROM machines LEFT JOIN machine_origins USING (device_id)`

const machineSelectSql = {
  all: `${MACHINE_SELECT} ORDER BY COALESCE(display_name, name), device_id`,
  byDeviceId: `${MACHINE_SELECT} WHERE device_id = ?`
}
