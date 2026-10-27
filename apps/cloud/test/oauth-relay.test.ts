import { runInDurableObject, SELF } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"
import { z } from "zod"

import { MAX_QUEUED_BYTES } from "../src/device-queue.js"
import { OAUTH_ITEM_TTL_MS } from "../src/hub-inbox.js"
import { OAUTH_FLOW_TTL_MS } from "../src/oauth-relay.js"
import { BASE, devLogin, disconnect, hubStub } from "./cloud-test-support.js"
import {
  connectInboxMachine,
  machineIdentity,
  newInboxMachine,
  nextInboxItem,
  openInboxItem,
  queuedCount,
  withHubSql
} from "./inbox-test-support.js"
import { readJson } from "./json-test-support.js"

const FlowBody = z.object({ flowId: z.string(), redirectUri: z.string(), expiresAt: z.string() })

const registerFlow = (apiKey: string | undefined, flowId: unknown) =>
  SELF.fetch(`${BASE}/api/machine/oauth-flows`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(apiKey ? { "x-api-key": apiKey } : {}) },
    body: JSON.stringify({ flowId })
  })

const startFlow = async (apiKey: string, deviceId: string) => {
  const flowId = crypto.randomUUID().replaceAll("-", "")
  expect((await registerFlow(apiKey, flowId)).status).toBe(200)
  return { flowId, state: `${flowId}.${deviceId}.nonce-${crypto.randomUUID()}` }
}

const callback = (query: Record<string, string>) =>
  SELF.fetch(`${BASE}/oauth/callback?${new URLSearchParams(query).toString()}`)

describe("oauth flow registration", () => {
  it("returns the relay redirect uri for a fresh flow id", async () => {
    const machine = await machineIdentity(await devLogin())
    const flowId = crypto.randomUUID().replaceAll("-", "")

    const response = await registerFlow(machine.apiKey, flowId)

    expect(await readJson(response, FlowBody)).toEqual({
      flowId,
      redirectUri: `${BASE}/oauth/callback`,
      expiresAt: new Date(Date.now() + OAUTH_FLOW_TTL_MS).toISOString()
    })
    expect((await registerFlow(machine.apiKey, flowId)).status).toBe(409)
  })

  it("requires a machine credential and a well-formed flow id", async () => {
    const machine = await machineIdentity(await devLogin())

    expect((await registerFlow(undefined, "a".repeat(32))).status).toBe(401)
    expect((await registerFlow(machine.apiKey, "short")).status).toBe(400)
    expect((await registerFlow(machine.apiKey, "has.dots.in.it.for.sure")).status).toBe(400)
  })
})

describe("oauth callback relay", () => {
  it("seals the code to the device that started the flow", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const flow = await startFlow(machine.apiKey, machine.deviceId)

    const page = await callback({ state: flow.state, code: "auth-code" })

    expect(page.status).toBe(200)
    expect(page.headers.get("cache-control")).toBe("no-store")
    expect(await page.text()).toContain("You can return to Codevisor.")
    const frame = await nextInboxItem(machine.reader)
    expect(frame.kind).toBe("oauth")
    expect(openInboxItem(machine, frame)).toEqual({
      flowId: flow.flowId,
      state: flow.state,
      code: "auth-code"
    })
  })

  it("accepts each flow once", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const flow = await startFlow(machine.apiKey, machine.deviceId)

    expect((await callback({ state: flow.state, code: "first" })).status).toBe(200)
    const replay = await callback({ state: flow.state, code: "second" })

    expect(replay.status).toBe(400)
    expect(await replay.text()).toContain("This sign-in link has expired")
  })

  it("rejects malformed, unknown, mismatched and expired states", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const other = await newInboxMachine(token)
    const mismatched = await startFlow(machine.apiKey, machine.deviceId)
    const expired = await startFlow(machine.apiKey, machine.deviceId)

    expect((await callback({ code: "x" })).status).toBe(400)
    expect((await callback({ state: "only.two", code: "x" })).status).toBe(400)
    expect(
      (await callback({ state: `unknown-flow-id.${machine.deviceId}.n`, code: "x" })).status
    ).toBe(400)
    const wrongDevice = mismatched.state.replace(machine.deviceId, other.deviceId)
    expect((await callback({ state: wrongDevice, code: "x" })).status).toBe(400)
    vi.setSystemTime(Date.now() + OAUTH_FLOW_TTL_MS)
    expect((await callback({ state: expired.state, code: "x" })).status).toBe(400)
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
    expect(await queuedCount(token, other.deviceId)).toBe(0)
  })

  it("relays provider errors to the device", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const flow = await startFlow(machine.apiKey, machine.deviceId)

    const page = await callback({ state: flow.state, error: "access_denied" })

    expect(page.status).toBe(400)
    expect(await page.text()).toContain("access_denied")
    expect(openInboxItem(machine, await nextInboxItem(machine.reader))).toEqual({
      flowId: flow.flowId,
      state: flow.state,
      error: "access_denied"
    })
  })

  it("holds the callback for an offline machine for ten minutes", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const flow = await startFlow(machine.apiKey, machine.deviceId)
    await disconnect(token, machine.socket, "asleep")

    const page = await callback({ state: flow.state, code: "later" })

    expect(page.status).toBe(200)
    expect(await page.text()).toContain("Your machine is offline")
    const expiry = await withHubSql(
      token,
      (sql) =>
        sql
          .exec<{ expires_at: number }>(
            "SELECT expires_at FROM device_queue WHERE device_id = ?",
            machine.deviceId
          )
          .one().expires_at
    )
    expect(expiry).toBe(Date.now() + OAUTH_ITEM_TTL_MS)
    const awake = await connectInboxMachine(machine)
    expect(openInboxItem(machine, await nextInboxItem(awake.reader))).toMatchObject({
      code: "later"
    })
  })

  it("drops an unacked callback after its ttl", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const flow = await startFlow(machine.apiKey, machine.deviceId)
    await disconnect(token, machine.socket, "asleep")
    expect((await callback({ state: flow.state, code: "stale" })).status).toBe(200)

    await runInDurableObject(await hubStub(token), async (hub) => {
      vi.setSystemTime(Date.now() + OAUTH_ITEM_TTL_MS)
      await hub.alarm()
    })

    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("explains when the flow's machine is unknown to the hub or the queue is full", async () => {
    const token = await devLogin()
    const unknown = await machineIdentity(token)
    const unknownFlow = await startFlow(unknown.apiKey, unknown.deviceId)
    const machine = await newInboxMachine(token)
    const fullFlow = await startFlow(machine.apiKey, machine.deviceId)

    const unknownPage = await callback({ state: unknownFlow.state, code: "x" })
    expect(unknownPage.status).toBe(400)
    expect(await unknownPage.text()).toContain("Reconnect the machine to Codevisor Cloud")

    await withHubSql(token, (sql) =>
      sql.exec(
        "INSERT INTO device_queue (device_id, item_id, inbox_id, frame, bytes, expires_at) VALUES ('filler', 'filler', NULL, 'x', ?, ?)",
        MAX_QUEUED_BYTES,
        Date.now() + OAUTH_ITEM_TTL_MS
      )
    )
    try {
      const fullPage = await callback({ state: fullFlow.state, code: "x" })
      expect(fullPage.status).toBe(503)
      expect(await fullPage.text()).toContain("in a few minutes")
    } finally {
      await withHubSql(token, (sql) =>
        sql.exec("DELETE FROM device_queue WHERE device_id = 'filler'")
      )
    }
  })
})
