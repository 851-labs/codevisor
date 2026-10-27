import { machineSocketsForGeneration } from "./hub-delivery.js"
import { machineRow } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"

export interface QueuedItem {
  readonly deviceId: string
  readonly itemId: string
  readonly inboxId: string | null
  readonly frame: string
  readonly expiresAt: number
}

export const MAX_QUEUED_ITEMS = 10_000
export const MAX_QUEUED_BYTES = 64 * 1024 * 1024

export class DeviceQueue {
  constructor(
    private readonly sql: SqlStorage,
    private readonly net: HubSockets
  ) {}

  enqueue(items: readonly QueuedItem[]): boolean {
    if (wouldOverflow(queueUsage(this.sql), items)) return false

    for (const item of items) this.#store(item)
    for (const item of items) this.#push(item)
    return true
  }

  isOnline(deviceId: string): boolean {
    return this.#liveSockets(deviceId).length > 0
  }

  flush(socket: WebSocket, deviceId: string): void {
    for (const frame of queuedFrames(this.sql, deviceId)) {
      if (!this.net.send(socket, frame)) return
    }
  }

  acknowledge(deviceId: string, itemIds: readonly string[]): void {
    for (const itemId of itemIds) this.sql.exec(queueSql.deleteItem, deviceId, itemId)
  }

  sweep(now: number): void {
    this.sql.exec(queueSql.deleteExpired, now)
  }

  nextExpiry(): number | undefined {
    return this.sql.exec<ExpiryRow>(queueSql.nextExpiry).toArray()[0]?.expires_at ?? undefined
  }

  forgetDevice(deviceId: string): void {
    this.sql.exec(queueSql.deleteDevice, deviceId)
  }

  forgetInbox(inboxId: string): void {
    this.sql.exec(queueSql.deleteInbox, inboxId)
  }

  forgetSubscription(inboxId: string, deviceId: string): void {
    this.sql.exec(queueSql.deleteSubscription, inboxId, deviceId)
  }

  #store(item: QueuedItem): void {
    this.sql.exec(
      queueSql.insert,
      item.deviceId,
      item.itemId,
      item.inboxId,
      item.frame,
      item.frame.length,
      item.expiresAt
    )
  }

  #push(item: QueuedItem): void {
    for (const socket of this.#liveSockets(item.deviceId)) this.net.send(socket, item.frame)
  }

  #liveSockets(deviceId: string): WebSocket[] {
    const machine = machineRow(this.sql, deviceId)
    if (machine === undefined) return []

    return machineSocketsForGeneration(this.net, deviceId, machine.active_generation).filter(
      (socket) => this.net.isRoutable(socket)
    )
  }
}

interface QueueUsage extends Record<string, SqlStorageValue> {
  items: number
  bytes: number
}

const wouldOverflow = (usage: QueueUsage, items: readonly QueuedItem[]): boolean =>
  usage.items + items.length > MAX_QUEUED_ITEMS ||
  usage.bytes + totalBytes(items) > MAX_QUEUED_BYTES

const totalBytes = (items: readonly QueuedItem[]): number =>
  items.reduce((sum, item) => sum + item.frame.length, 0)

const queueUsage = (sql: SqlStorage): QueueUsage => sql.exec<QueueUsage>(queueSql.usage).one()

const queuedFrames = (sql: SqlStorage, deviceId: string): string[] =>
  sql
    .exec<FrameRow>(queueSql.framesForDevice, deviceId)
    .toArray()
    .map((row) => row.frame)

interface ExpiryRow extends Record<string, SqlStorageValue> {
  expires_at: number | null
}

interface FrameRow extends Record<string, SqlStorageValue> {
  frame: string
}

const queueSql = {
  insert: `INSERT INTO device_queue (device_id, item_id, inbox_id, frame, bytes, expires_at)
     VALUES (?, ?, ?, ?, ?, ?)`,
  usage: "SELECT COUNT(*) AS items, COALESCE(SUM(bytes), 0) AS bytes FROM device_queue",
  framesForDevice: "SELECT frame FROM device_queue WHERE device_id = ? ORDER BY seq",
  deleteItem: "DELETE FROM device_queue WHERE device_id = ? AND item_id = ?",
  deleteExpired: "DELETE FROM device_queue WHERE expires_at <= ?",
  nextExpiry: "SELECT MIN(expires_at) AS expires_at FROM device_queue",
  deleteDevice: "DELETE FROM device_queue WHERE device_id = ?",
  deleteInbox: "DELETE FROM device_queue WHERE inbox_id = ?",
  deleteSubscription: "DELETE FROM device_queue WHERE inbox_id = ? AND device_id = ?"
}
