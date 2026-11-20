import { runInDurableObject, SELF } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"
import { z } from "zod"

import { MAX_QUEUED_BYTES } from "../src/device-queue.js"
import { OAUTH_ITEM_TTL_MS } from "../src/hub-inbox.js"
import { flowIdOf, OAUTH_FLOW_TTL_MS } from "../src/oauth-relay.js"
import { BASE, devLogin, disconnect, hubStub } from "./cloud-test-support.js"
import {
  connectInboxMachine,
  type InboxMachine,
  machineIdentity,
  newInboxMachine,
  nextInboxItem,
  openInboxItem,
  queuedCount,
  withHubSql
} from "./inbox-test-support.js"
import { readJson } from "./json-test-support.js"

const FlowBody = z.object({ redirectUri: z.string(), expiresAt: z.string() })

const registerFlow = (apiKey: string | undefined, body: unknown) =>
  SELF.fetch(`${BASE}/api/machine/oauth-flows`, {
    method: "POST",
    headers: { "content-type": "application/json", ...(apiKey ? { "x-api-key": apiKey } : {}) },
    body: JSON.stringify(body)
  })

const startFlow = async (apiKey: string, extra: Record<string, unknown> = {}) => {
  const state = `server-1.${crypto.randomUUID()}`
  const registered = await registerFlow(apiKey, { flowId: await flowIdOf(state), ...extra })
  expect(registered.status).toBe(200)
  return state
}

const answer = (machine: InboxMachine, itemId: string, result: Record<string, unknown>) =>
  machine.socket.send(
    JSON.stringify({ t: "inbox-ack", itemIds: [itemId], results: [{ itemId, ...result }] })
  )

const callback = (query: Record<string, string>, path = "/oauth/callback") =>
  SELF.fetch(`${BASE}${path}?${new URLSearchParams(query).toString()}`, { redirect: "manual" })

describe("oauth flow registration", () => {
  it("answers with the Cloud callback and refuses a second registration of the same flow", async () => {
    const machine = await machineIdentity(await devLogin())
    const flowId = await flowIdOf("server-1.state")

    const response = await registerFlow(machine.apiKey, { flowId })

    expect(await readJson(response, FlowBody)).toEqual({
      redirectUri: `${BASE}/oauth/callback`,
      expiresAt: new Date(Date.now() + OAUTH_FLOW_TTL_MS).toISOString()
    })
    expect((await registerFlow(machine.apiKey, { flowId })).status).toBe(409)
  })

  it("registers a client's fixed redirect only when it is one of this Cloud's callbacks", async () => {
    const machine = await machineIdentity(await devLogin())
    const legacy = `${BASE}/oauth/plugins/callback`
    const register = async (state: string, redirectUris: Array<string>) =>
      registerFlow(machine.apiKey, { flowId: await flowIdOf(state), redirectUris })

    const served = await register("s-1", ["http://localhost", legacy])
    const foreign = await register("s-2", ["https://cloud.other/oauth/callback"])

    expect(await readJson(served, FlowBody)).toMatchObject({ redirectUri: legacy })
    expect(foreign.status).toBe(422)
    expect((await callback({ state: "s-2", code: "x" })).status).toBe(400)
  })

  it("needs a machine credential and a SHA-256 flow id", async () => {
    const machine = await machineIdentity(await devLogin())

    expect((await registerFlow(undefined, { flowId: "a".repeat(43) })).status).toBe(401)
    expect((await registerFlow(machine.apiKey, { flowId: "short" })).status).toBe(400)
    expect((await registerFlow(machine.apiKey, { flowId: `${"a".repeat(42)}.` })).status).toBe(400)
  })
})

describe("oauth callback relay", () => {
  it("says signed in, and opens the app, only after the machine redeemed the code", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const other = await newInboxMachine(token)
    const state = await startFlow(machine.apiKey, { app: "codevisor-dev", opensApp: true })

    const pending = callback({ state, code: "auth-code", iss: "https://auth.example" })
    const frame = await nextInboxItem(machine.reader)
    answer(machine, frame.itemId, { ok: true })
    const page = await pending

    expect(page.status).toBe(200)
    expect(page.headers.get("cache-control")).toBe("no-store")
    const html = await page.text()
    expect(html).toContain("inbox machine finished signing in")
    expect(html).toContain('location.href = "codevisor-dev://signed-in"')
    expect(frame.kind).toBe("oauth")
    expect(openInboxItem(machine, frame)).toEqual({
      state,
      code: "auth-code",
      iss: "https://auth.example"
    })
    expect(await queuedCount(token, other.deviceId)).toBe(0)
  })

  it("passes on the machine's reason when it couldn't redeem the code", async () => {
    const machine = await newInboxMachine(await devLogin())
    const state = await startFlow(machine.apiKey, { app: "codevisor-dev", opensApp: true })

    const pending = callback({ state, code: "auth-code" })
    answer(machine, (await nextInboxItem(machine.reader)).itemId, {
      ok: false,
      error: "The code expired"
    })
    const page = await pending

    expect(page.status).toBe(400)
    const html = await page.text()
    expect(html).toContain("finish signing in: The code expired")
    expect(html).not.toContain("location.href")
  })

  it("says it is still finishing when an online machine doesn't answer in time", async () => {
    const machine = await newInboxMachine(await devLogin())
    const state = await startFlow(machine.apiKey, { app: "codevisor" })

    const page = await callback({ state, code: "auth-code" })

    expect(page.status).toBe(200)
    const html = await page.text()
    expect(html).toContain("Still finishing")
    expect(html).toContain('href="codevisor://signed-in"')
    expect(html).not.toContain("location.href")
  })

  it("serves an already-signed-in page any device can open", async () => {
    const page = await SELF.fetch(`${BASE}/oauth/signed-in?app=codevisor-dev`)
    const unknownApp = await SELF.fetch(`${BASE}/oauth/signed-in?app=javascript`)

    expect(page.status).toBe(200)
    expect(await page.text()).toContain('location.href = "codevisor-dev://signed-in"')
    expect(await unknownApp.text()).not.toContain("location.href")
  })

  it("routes each flow once, and never after it expires", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const used = await startFlow(machine.apiKey)
    const stale = await startFlow(machine.apiKey)

    expect((await callback({ state: used, code: "first" })).status).toBe(200)
    const replay = await callback({ state: used, code: "second" })
    vi.setSystemTime(Date.now() + OAUTH_FLOW_TTL_MS)
    const expired = await callback({ state: stale, code: "late" })
    const unknown = await callback({ state: "server-1.never-registered", code: "x" })

    expect([replay.status, expired.status, unknown.status]).toEqual([400, 400, 400])
    expect(await replay.text()).toContain("This sign-in link has expired")
    await nextInboxItem(machine.reader)
    expect(await queuedCount(token, machine.deviceId)).toBe(1)
  })

  it("relays a provider's error and says sign-in didn't finish", async () => {
    const machine = await newInboxMachine(await devLogin())
    const state = await startFlow(machine.apiKey)

    const page = await callback({ state, error: "access_denied" })

    expect(page.status).toBe(400)
    expect(await page.text()).toContain("access_denied")
    expect(openInboxItem(machine, await nextInboxItem(machine.reader))).toEqual({
      state,
      error: "access_denied"
    })
  })

  it("holds the callback for an offline machine for a few minutes and says so", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const state = await startFlow(machine.apiKey)
    await disconnect(token, machine.socket, "asleep")

    const page = await callback({ state, code: "later" })

    expect(page.status).toBe(200)
    expect(await page.text()).toContain("inbox machine is offline right now")
    const awake = await connectInboxMachine(machine)
    expect(openInboxItem(machine, await nextInboxItem(awake.reader))).toMatchObject({
      code: "later"
    })
  })

  it("drops an undelivered callback once its few minutes are up", async () => {
    const token = await devLogin()
    const machine = await newInboxMachine(token)
    const state = await startFlow(machine.apiKey)
    await disconnect(token, machine.socket, "asleep")
    expect((await callback({ state, code: "stale" })).status).toBe(200)

    await runInDurableObject(await hubStub(token), async (hub) => {
      vi.setSystemTime(Date.now() + OAUTH_ITEM_TTL_MS)
      await hub.alarm()
    })

    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("tells the user to start again when the machine left the account or the queue is full", async () => {
    const token = await devLogin()
    const unknown = await machineIdentity(token)
    const unknownState = await startFlow(unknown.apiKey)
    const machine = await newInboxMachine(token)
    const fullState = await startFlow(machine.apiKey)

    const unknownPage = await callback({ state: unknownState, code: "x" })
    expect(unknownPage.status).toBe(400)
    expect(await unknownPage.text()).toContain("start signing in again")

    await withHubSql(token, (sql) =>
      sql.exec(
        "INSERT INTO device_queue (device_id, item_id, inbox_id, frame, bytes, expires_at) VALUES ('filler', 'filler', NULL, 'x', ?, ?)",
        MAX_QUEUED_BYTES,
        Date.now() + OAUTH_ITEM_TTL_MS
      )
    )
    try {
      const fullPage = await callback({ state: fullState, code: "x" })
      expect(fullPage.status).toBe(503)
      expect(await fullPage.text()).toContain("in a few minutes")
    } finally {
      await withHubSql(token, (sql) =>
        sql.exec("DELETE FROM device_queue WHERE device_id = 'filler'")
      )
    }
  })

  it("relays registered flows on the older plugin callback path and still bounces the rest to the app", async () => {
    const machine = await newInboxMachine(await devLogin())
    const state = await startFlow(machine.apiKey)
    const appState = "Qm9nT3V0RmxvdzAxMjM0NTY3ODlhYmNk.codevisor.bm9uY2UwMTIz"

    const relayed = await callback({ state, code: "c-1" }, "/oauth/plugins/callback")
    const bounced = await callback({ state: appState, code: "c-2" }, "/oauth/plugins/callback")

    expect(relayed.status).toBe(200)
    expect(openInboxItem(machine, await nextInboxItem(machine.reader))).toMatchObject({
      code: "c-1"
    })
    expect(bounced.headers.get("location")).toBe(
      `codevisor://plugin-oauth?${new URLSearchParams({ state: appState, code: "c-2" }).toString()}`
    )
  })
})
