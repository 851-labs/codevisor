import { env, runInDurableObject, SELF } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"

import { MAX_QUEUED_BYTES, MAX_QUEUED_ITEMS } from "../src/device-queue.js"
import { INBOX_ITEM_TTL_MS, INBOX_RATE_LIMIT, INBOX_RATE_WINDOW_MS } from "../src/hub-inbox.js"
import { MAX_INBOXES_PER_USER } from "../src/inbox-store.js"
import { authed, BASE, devLogin, disconnect, hubStub } from "./cloud-test-support.js"
import {
  createInbox,
  InboxBody,
  machineIdentity,
  newInboxMachine,
  postWebhook,
  provisionTestInbox,
  queuedCount,
  signUpUser,
  subscribe,
  withHubSql
} from "./inbox-test-support.js"
import { readJson, SessionUserBody } from "./json-test-support.js"

const fillerDevice = "filler-device"

const seedFiller = (token: string, items: number, bytesEach: number) =>
  withHubSql(token, (sql) =>
    sql.exec(
      `WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
       INSERT INTO device_queue (device_id, item_id, inbox_id, frame, bytes, expires_at)
       SELECT ?, 'filler-' || i, NULL, 'x', ?, ? FROM n`,
      items,
      fillerDevice,
      bytesEach,
      Date.now() + INBOX_ITEM_TTL_MS
    )
  )

const clearFiller = (token: string) =>
  withHubSql(token, (sql) => sql.exec("DELETE FROM device_queue WHERE device_id = ?", fillerDevice))

const sessionUserId = async (token: string): Promise<string> => {
  const response = await SELF.fetch(`${BASE}/api/auth/get-session`, { headers: authed(token) })
  const body = await readJson(response, SessionUserBody)
  if (body === null) throw new Error("expected a session")
  return body.user.id
}

const offlineSubscriber = async (token: string) => {
  const machine = await newInboxMachine(token)
  const inbox = await provisionTestInbox(machine.apiKey)
  await subscribe(machine, inbox.id)
  await disconnect(token, machine.socket, "offline")
  return { machine, inbox }
}

describe("inbox limits", () => {
  it("rate limits each inbox per window", async () => {
    const token = await devLogin()
    const { inbox } = await offlineSubscriber(token)
    const window = Date.now() - (Date.now() % INBOX_RATE_WINDOW_MS)
    await withHubSql(token, (sql) =>
      sql.exec(
        "INSERT INTO inbox_rates (inbox_id, window_start, count) VALUES (?, ?, ?)",
        inbox.id,
        window,
        INBOX_RATE_LIMIT - 1
      )
    )

    expect((await postWebhook(inbox.url, "last")).status).toBe(202)
    const limited = await postWebhook(inbox.url, "over")
    expect(limited.status).toBe(429)
    expect(limited.headers.get("retry-after")).toBe("60")

    vi.setSystemTime(window + INBOX_RATE_WINDOW_MS)
    expect((await postWebhook(inbox.url, "next window")).status).toBe(202)
  })

  it("refuses new items once the account's queue reaches its byte cap", async () => {
    const token = await devLogin()
    const { inbox } = await offlineSubscriber(token)
    await seedFiller(token, 1, MAX_QUEUED_BYTES)

    try {
      expect((await postWebhook(inbox.url, "x")).status).toBe(503)
    } finally {
      await clearFiller(token)
    }
    expect((await postWebhook(inbox.url, "x")).status).toBe(202)
  })

  it("refuses new items once the account's queue reaches its item cap", async () => {
    const token = await devLogin()
    const { inbox } = await offlineSubscriber(token)
    const queued = await withHubSql(
      token,
      (sql) => sql.exec<{ count: number }>("SELECT COUNT(*) AS count FROM device_queue").one().count
    )
    await seedFiller(token, MAX_QUEUED_ITEMS - queued, 1)

    try {
      const full = await postWebhook(inbox.url, "x")
      expect(full.status).toBe(503)
      expect(full.headers.get("retry-after")).toBe("60")
    } finally {
      await clearFiller(token)
    }
  })

  it("sweeps expired items and schedules the sweep alarm", async () => {
    const token = await devLogin()
    const { machine, inbox } = await offlineSubscriber(token)
    await runInDurableObject(await hubStub(token), async (hub, state) => {
      await hub.alarm()
      await state.storage.deleteAlarm()
    })

    expect((await postWebhook(inbox.url, "expiring")).status).toBe(202)
    const expiresAt = Date.now() + INBOX_ITEM_TTL_MS

    await runInDurableObject(await hubStub(token), async (hub, state) => {
      expect(await state.storage.getAlarm()).toBeLessThanOrEqual(expiresAt)
      vi.setSystemTime(expiresAt - 1)
      await hub.alarm()
    })
    expect(await queuedCount(token, machine.deviceId)).toBe(1)

    await runInDurableObject(await hubStub(token), async (hub) => {
      vi.setSystemTime(expiresAt)
      await hub.alarm()
    })
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("drops a removed machine's subscriptions and queue", async () => {
    const token = await devLogin()
    const { machine, inbox } = await offlineSubscriber(token)
    expect((await postWebhook(inbox.url, "pending")).status).toBe(202)

    const removed = await SELF.fetch(`${BASE}/api/machines/${machine.deviceId}`, {
      method: "DELETE",
      headers: authed(token)
    })
    expect(removed.status).toBe(200)

    expect(await queuedCount(token, machine.deviceId)).toBe(0)
    const subscribers = await withHubSql(
      token,
      (sql) =>
        sql
          .exec<{ count: number }>(
            "SELECT COUNT(*) AS count FROM inbox_subscribers WHERE device_id = ?",
            machine.deviceId
          )
          .one().count
    )
    expect(subscribers).toBe(0)
  })

  it("caps inboxes per account but still returns existing ones", async () => {
    const token = await signUpUser()
    const machine = await machineIdentity(token)
    const userId = await sessionUserId(token)
    await env.DB.batch(
      Array.from({ length: MAX_INBOXES_PER_USER }, (_, index) =>
        env.DB.prepare(
          "INSERT INTO inbox (id, user_id, plugin, account_id, ingress, created_at) VALUES (?, ?, 'seed', ?, 'hook', 0)"
        ).bind(`seed-${index}-${userId}`, userId, String(index))
      )
    )

    const over = await createInbox(machine.apiKey, {
      plugin: "grafana",
      accountId: "one-too-many",
      ingress: "alerts"
    })
    expect(over.status).toBe(409)
    const repeat = await createInbox(machine.apiKey, {
      plugin: "seed",
      accountId: "0",
      ingress: "hook"
    })
    expect(repeat.status).toBe(200)
    expect((await readJson(repeat, InboxBody)).id).toBe(`seed-0-${userId}`)
  })
})
