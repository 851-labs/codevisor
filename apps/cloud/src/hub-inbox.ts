import { DeviceQueue, type QueuedItem } from "./device-queue.js"
import { machineRow } from "./hub-schema.js"
import type { HubSockets } from "./hub-sockets.js"
import { sealInboxItem, type InboxRequest, type WebhookItem } from "./inbox-frames.js"

export type IngestOutcome = "accepted" | "rate-limited" | "full"
export type SubscribeOutcome = "subscribed" | "unknown-device"

export const INBOX_ITEM_TTL_MS = 7 * 24 * 60 * 60 * 1000
export const INBOX_RATE_WINDOW_MS = 60 * 1000
export const INBOX_RATE_LIMIT = 120

export class HubInbox {
  readonly #queue: DeviceQueue

  constructor(
    private readonly sql: SqlStorage,
    net: HubSockets
  ) {
    this.#queue = new DeviceQueue(sql, net)
  }

  subscribe(inboxId: string, deviceId: string): SubscribeOutcome {
    if (machineRow(this.sql, deviceId) === undefined) return "unknown-device"

    this.sql.exec(subscriberSql.insert, inboxId, deviceId)
    return "subscribed"
  }

  unsubscribe(inboxId: string, deviceId: string): void {
    this.sql.exec(subscriberSql.delete, inboxId, deviceId)
    this.#queue.forgetSubscription(inboxId, deviceId)
  }

  revoke(inboxId: string): void {
    this.sql.exec(subscriberSql.deleteInbox, inboxId)
    this.sql.exec(rateSql.deleteInbox, inboxId)
    this.#queue.forgetInbox(inboxId)
  }

  forgetDevice(deviceId: string): void {
    this.sql.exec(subscriberSql.deleteDevice, deviceId)
    this.#queue.forgetDevice(deviceId)
  }

  ingest(inboxId: string, request: InboxRequest, now: number): IngestOutcome {
    if (this.#overRate(inboxId, now)) return "rate-limited"

    const item: WebhookItem = { itemId: crypto.randomUUID(), inboxId, ...request }
    const expiresAt = now + INBOX_ITEM_TTL_MS
    const queued = subscribers(this.sql, inboxId).map((device) =>
      sealedItem(device, item, expiresAt)
    )
    return this.#queue.enqueue(queued) ? "accepted" : "full"
  }

  acknowledge(deviceId: string, itemIds: readonly string[]): void {
    this.#queue.acknowledge(deviceId, itemIds)
  }

  flush(socket: WebSocket, deviceId: string): void {
    this.#queue.flush(socket, deviceId)
  }

  sweep(now: number): void {
    this.#queue.sweep(now)
    this.sql.exec(rateSql.deleteStale, rateWindow(now))
  }

  nextExpiry(): number | undefined {
    return this.#queue.nextExpiry()
  }

  #overRate(inboxId: string, now: number): boolean {
    const row = this.sql.exec<RateRow>(rateSql.count, inboxId, rateWindow(now)).one()
    return row.count > INBOX_RATE_LIMIT
  }
}

const rateWindow = (now: number): number => now - (now % INBOX_RATE_WINDOW_MS)

const sealedItem = (device: SubscriberRow, item: WebhookItem, expiresAt: number): QueuedItem => ({
  deviceId: device.device_id,
  itemId: item.itemId,
  inboxId: item.inboxId,
  frame: JSON.stringify(sealInboxItem(device.public_key, item)),
  expiresAt
})

const subscribers = (sql: SqlStorage, inboxId: string): SubscriberRow[] =>
  sql.exec<SubscriberRow>(subscriberSql.withKeys, inboxId).toArray()

interface SubscriberRow extends Record<string, SqlStorageValue> {
  device_id: string
  public_key: string
}

interface RateRow extends Record<string, SqlStorageValue> {
  count: number
}

const subscriberSql = {
  insert: `INSERT INTO inbox_subscribers (inbox_id, device_id) VALUES (?, ?)
     ON CONFLICT(inbox_id, device_id) DO NOTHING`,
  delete: "DELETE FROM inbox_subscribers WHERE inbox_id = ? AND device_id = ?",
  deleteInbox: "DELETE FROM inbox_subscribers WHERE inbox_id = ?",
  deleteDevice: "DELETE FROM inbox_subscribers WHERE device_id = ?",
  withKeys: `SELECT inbox_subscribers.device_id, machines.public_key
     FROM inbox_subscribers JOIN machines USING (device_id)
     WHERE inbox_subscribers.inbox_id = ?
     ORDER BY inbox_subscribers.device_id`
}

const rateSql = {
  count: `INSERT INTO inbox_rates (inbox_id, window_start, count) VALUES (?, ?, 1)
     ON CONFLICT(inbox_id) DO UPDATE SET
       count = CASE WHEN window_start = excluded.window_start THEN count + 1 ELSE 1 END,
       window_start = excluded.window_start
     RETURNING count`,
  deleteInbox: "DELETE FROM inbox_rates WHERE inbox_id = ?",
  deleteStale: "DELETE FROM inbox_rates WHERE window_start < ?"
}
