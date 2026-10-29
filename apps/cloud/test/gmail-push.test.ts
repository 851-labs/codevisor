import { env, SELF } from "cloudflare:test"
import { exportJWK, generateKeyPair, SignJWT, type JWTPayload } from "jose"
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest"

import type { CloudEnv } from "../src/env.js"
import { googleCertsUrl, gmailRouteKey } from "../src/gmail-push.js"
import { GMAIL_PUSH_OFF } from "../src/inbox-route-configs.js"
import worker from "../src/index.js"
import { BASE } from "./cloud-test-support.js"
import {
  newInboxMachine,
  nextInboxItem,
  openWebhookItem,
  provisionTestInbox,
  queuedCount,
  signUpUser,
  subscribe
} from "./inbox-test-support.js"

const audience = "test-push-audience"
const serviceAccount = "gmail-push@codevisor-test.iam.gserviceaccount.com"
const topic = "projects/codevisor-test/topics/gmail"
const mailbox = "Dylan@851.sh"

let pushEnv: CloudEnv
let offEnv: CloudEnv
let googleKey: CryptoKey
let strangerKey: CryptoKey
let jwks: { keys: Array<Record<string, unknown>> }

beforeAll(async () => {
  const google = await generateKeyPair("RS256")
  googleKey = google.privateKey
  strangerKey = (await generateKeyPair("RS256")).privateKey
  jwks = { keys: [{ ...(await exportJWK(google.publicKey)), kid: "google-test", alg: "RS256" }] }
  offEnv = {
    ...env,
    GMAIL_PUSH_AUDIENCE: "",
    GMAIL_PUSH_SERVICE_ACCOUNT: "",
    GMAIL_PUSH_TOPIC: ""
  }
  pushEnv = {
    ...env,
    GMAIL_PUSH_AUDIENCE: audience,
    GMAIL_PUSH_SERVICE_ACCOUNT: serviceAccount,
    GMAIL_PUSH_TOPIC: topic
  }
})

beforeEach(() => {
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = new Request(input).url
    if (url === googleCertsUrl) return Response.json(jwks)
    throw new Error(`Unexpected outbound request: ${url}`)
  })
})

afterEach(() => vi.restoreAllMocks())

const pushToken = (
  claims: JWTPayload = {},
  key: CryptoKey = googleKey,
  expiresIn = "5m",
  tokenAudience = audience
) =>
  new SignJWT({ email: serviceAccount, email_verified: true, ...claims })
    .setProtectedHeader({ alg: "RS256", kid: "google-test" })
    .setIssuer("https://accounts.google.com")
    .setAudience(tokenAudience)
    .setSubject("1234567890")
    .setIssuedAt()
    .setExpirationTime(expiresIn)
    .sign(key)

const envelope = (data: unknown) => ({
  message: {
    data: Buffer.from(typeof data === "string" ? data : JSON.stringify(data)).toString("base64"),
    messageId: "2070443601311540",
    publishTime: "2026-10-29T18:00:00.000Z"
  },
  subscription: "projects/codevisor-test/subscriptions/gmail-push"
})

const push = async (
  body: unknown,
  token: string | undefined,
  { path = "/push/gmail", cloudEnv = pushEnv }: { path?: string; cloudEnv?: CloudEnv } = {}
) =>
  worker.fetch(
    new Request(`${BASE}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        ...(token === undefined ? {} : { authorization: `Bearer ${token}` })
      },
      body: JSON.stringify(body)
    }),
    cloudEnv
  )

const routeRequest = (apiKey: string, inboxId: string, body: unknown, route = "gmail") =>
  new Request(`${BASE}/api/machine/inboxes/${inboxId}/routes/${route}`, {
    method: "PUT",
    headers: { "content-type": "application/json", "x-api-key": apiKey },
    body: JSON.stringify(body)
  })

const routeTo = async (apiKey: string, inboxId: string, address = mailbox) =>
  worker.fetch(routeRequest(apiKey, inboxId, { key: await gmailRouteKey(address) }), pushEnv)

const routedMachine = async () => {
  const token = await signUpUser()
  const machine = await newInboxMachine(token)
  const inbox = await provisionTestInbox(machine.apiKey)
  await subscribe(machine, inbox.id)
  expect((await routeTo(machine.apiKey, inbox.id)).status).toBe(200)
  return { token, machine, inbox }
}

describe("gmail push routes", () => {
  it("routes a machine's inbox by its address hash and hands back the cloud's topic", async () => {
    const token = await signUpUser()
    const machine = await newInboxMachine(token)
    const inbox = await provisionTestInbox(machine.apiKey)
    const stranger = await newInboxMachine(await signUpUser())

    const routed = await routeTo(machine.apiKey, inbox.id)
    const badKey = await worker.fetch(
      routeRequest(machine.apiKey, inbox.id, { key: mailbox }),
      pushEnv
    )
    const unknownRoute = await worker.fetch(
      routeRequest(machine.apiKey, inbox.id, { key: await gmailRouteKey(mailbox) }, "constructor"),
      pushEnv
    )
    const notTheirs = await routeTo(stranger.apiKey, inbox.id)
    const turnedOff = await worker.fetch(
      routeRequest(machine.apiKey, inbox.id, { key: await gmailRouteKey(mailbox) }),
      offEnv
    )

    expect(routed.status).toBe(200)
    expect(await routed.json()).toEqual({ config: { topic } })
    expect([badKey.status, unknownRoute.status, notTheirs.status]).toEqual([400, 404, 404])
    expect(turnedOff.status).toBe(503)
    expect(await turnedOff.json()).toEqual({ error: GMAIL_PUSH_OFF })
  })
})

describe("gmail push endpoint", () => {
  it("relays only the address and history id to every device routed for that mailbox", async () => {
    const { token, machine, inbox } = await routedMachine()
    const laptop = await newInboxMachine(token)
    await subscribe(laptop, inbox.id)

    const response = await push(
      envelope({ emailAddress: "dylan@851.sh", historyId: 4242 }),
      await pushToken()
    )
    const [onMachine, onLaptop] = await Promise.all([
      nextInboxItem(machine.reader),
      nextInboxItem(laptop.reader)
    ])

    expect(response.status).toBe(204)
    for (const [identity, frame] of [
      [machine, onMachine],
      [laptop, onLaptop]
    ] as const) {
      const item = openWebhookItem(identity, frame)
      expect(item).toMatchObject({
        inboxId: inbox.id,
        method: "POST",
        headers: { "content-type": "application/json" }
      })
      expect(JSON.parse(Buffer.from(item.body, "base64").toString("utf8"))).toEqual({
        emailAddress: "dylan@851.sh",
        historyId: "4242"
      })
    }
  })

  it("accepts the hooks-host path and leaves other mailboxes alone", async () => {
    const { token, machine } = await routedMachine()

    const elsewhere = await push(
      envelope({ emailAddress: "someone@example.com", historyId: "1" }),
      await pushToken()
    )
    const hooksPath = await push(
      envelope({ emailAddress: mailbox, historyId: "2" }),
      await pushToken(),
      {
        path: "/hooks/push/gmail"
      }
    )
    const item = openWebhookItem(machine, await nextInboxItem(machine.reader))

    expect([elsewhere.status, hooksPath.status]).toEqual([204, 204])
    expect(JSON.parse(Buffer.from(item.body, "base64").toString("utf8"))).toMatchObject({
      historyId: "2"
    })
    expect(await queuedCount(token, machine.deviceId)).toBe(1)
  })

  it("rejects anything that isn't a fresh, verified token from the Gmail push service account", async () => {
    const { token, machine } = await routedMachine()
    const body = envelope({ emailAddress: mailbox, historyId: "7" })

    const statuses = await Promise.all([
      push(body, undefined),
      push(body, "not-a-jwt"),
      push(body, await pushToken({}, googleKey, "5m", "someone-else")),
      push(body, await pushToken({ email: "attacker@example.com" })),
      push(body, await pushToken({ email_verified: false })),
      push(body, await pushToken({}, strangerKey)),
      push(body, await pushToken({}, googleKey, "-1m"))
    ])

    expect(statuses.map((response) => response.status)).toEqual([401, 401, 401, 401, 401, 401, 401])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("acknowledges malformed notifications without relaying them, so Pub/Sub doesn't retry", async () => {
    const { token, machine } = await routedMachine()

    const statuses = await Promise.all([
      push({ nope: true }, await pushToken()),
      push(envelope("not json"), await pushToken()),
      push(envelope({ emailAddress: mailbox, historyId: "abc" }), await pushToken())
    ])

    expect(statuses.map((response) => response.status)).toEqual([204, 204, 204])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("stops routing to an inbox once it's deleted", async () => {
    const { token, machine, inbox } = await routedMachine()

    const deleted = await SELF.fetch(`${BASE}/api/machine/inboxes/${inbox.id}`, {
      method: "DELETE",
      headers: { "x-api-key": machine.apiKey }
    })
    const response = await push(
      envelope({ emailAddress: mailbox, historyId: "9" }),
      await pushToken()
    )

    expect([deleted.status, response.status]).toEqual([200, 204])
    expect(await queuedCount(token, machine.deviceId)).toBe(0)
  })

  it("is off until the cloud has push settings", async () => {
    const response = await push(
      envelope({ emailAddress: mailbox, historyId: "1" }),
      await pushToken(),
      {
        cloudEnv: offEnv
      }
    )

    expect(response.status).toBe(404)
  })
})
