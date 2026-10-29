import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  encodeCloudFrame,
  type HubToMachine
} from "@codevisor/api"
import {
  acceptChannel,
  fromBase64Url,
  generateDeviceKeyPair,
  openJson
} from "@codevisor/cloud-crypto"
import { runInDurableObject, SELF } from "cloudflare:test"
import { expect } from "vitest"
import { z } from "zod"

import type { InboxItemFrame } from "../src/inbox-frames.js"
import { authed, BASE, connectSocket, hubStub, SocketReader } from "./cloud-test-support.js"
import { KeyBody, readJson, TokenBody } from "./json-test-support.js"

export type InboxHubFrame = HubToMachine | InboxItemFrame

export interface MachineIdentity {
  readonly apiKey: string
  readonly deviceId: string
  readonly keys: ReturnType<typeof generateDeviceKeyPair>
}

export interface InboxMachine extends MachineIdentity {
  readonly socket: WebSocket
  readonly reader: SocketReader<InboxHubFrame>
}

export const InboxBody = z.object({ id: z.string(), url: z.string() })

export const signUpUser = async (): Promise<string> => {
  const response = await SELF.fetch(`${BASE}/api/auth/sign-up/email`, {
    method: "POST",
    headers: { "content-type": "application/json", origin: BASE },
    body: JSON.stringify({
      email: `${crypto.randomUUID()}@codevisor.test`,
      password: "inbox-test-password",
      name: "Inbox User"
    })
  })
  expect(response.status).toBe(200)
  return (await readJson(response, TokenBody)).token
}

export const machineIdentity = async (token: string): Promise<MachineIdentity> => {
  const deviceId = crypto.randomUUID()
  const keys = generateDeviceKeyPair()
  const created = await SELF.fetch(`${BASE}/api/auth/api-key/create`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authed(token) },
    body: JSON.stringify({ name: "inbox test", metadata: { deviceId, publicKey: keys.publicKey } })
  })
  expect(created.status).toBe(200)
  return { apiKey: (await readJson(created, KeyBody)).key, deviceId, keys }
}

export const connectInboxMachine = async (identity: MachineIdentity): Promise<InboxMachine> => {
  const socket = await connectSocket({ "x-api-key": identity.apiKey })
  const reader = new SocketReader<InboxHubFrame>(socket, decodeInboxHubFrame)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId: identity.deviceId,
        kind: "machine",
        name: "inbox machine",
        publicKey: identity.keys.publicKey
      }
    })
  )
  await reader.nextFrame("welcome")
  return { ...identity, socket, reader }
}

export const newInboxMachine = async (token: string): Promise<InboxMachine> =>
  connectInboxMachine(await machineIdentity(token))

export const nextInboxItem = async (reader: SocketReader<InboxHubFrame>) => {
  for (;;) {
    const frame = await reader.next()
    if (frame.t === "inbox-item") return frame
  }
}

type SealedFrame = Pick<InboxItemFrame, "itemId" | "sender" | "ephemeralKey" | "sealed">

export const openInboxItem = (identity: MachineIdentity, frame: SealedFrame): unknown =>
  openJson(
    acceptChannel(identity.keys.secretKey, frame.sender, frame.ephemeralKey),
    frame.itemId,
    "opener-to-responder",
    0,
    fromBase64Url(frame.sealed)
  )

export const WebhookItemBody = z.object({
  itemId: z.string(),
  inboxId: z.string(),
  method: z.string(),
  headers: z.record(z.string(), z.string()),
  body: z.string(),
  receivedAt: z.string()
})

export const openWebhookItem = (identity: MachineIdentity, frame: SealedFrame) =>
  WebhookItemBody.parse(openInboxItem(identity, frame))

export const createInbox = (apiKey: string, body: unknown): Promise<Response> =>
  SELF.fetch(`${BASE}/api/machine/inboxes`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-api-key": apiKey },
    body: JSON.stringify(body)
  })

export const provisionTestInbox = async (apiKey: string) => {
  const response = await createInbox(apiKey, {
    plugin: "grafana",
    accountId: crypto.randomUUID(),
    ingress: "alerts"
  })
  expect(response.status).toBe(200)
  return readJson(response, InboxBody)
}

export const subscription = (apiKey: string, inboxId: string, method: "PUT" | "DELETE") =>
  SELF.fetch(`${BASE}/api/machine/inboxes/${inboxId}/devices/self`, {
    method,
    headers: { "x-api-key": apiKey }
  })

export const subscribe = async (machine: MachineIdentity, inboxId: string): Promise<void> => {
  expect((await subscription(machine.apiKey, inboxId, "PUT")).status).toBe(200)
}

export const postWebhook = (url: string, body: string, headers: Record<string, string> = {}) =>
  SELF.fetch(url, { method: "POST", headers, body })

export const queuedCount = async (token: string, deviceId: string): Promise<number> =>
  runInDurableObject(await hubStub(token), (_hub, state) =>
    state.storage.sql
      .exec<{ count: number }>(
        "SELECT COUNT(*) AS count FROM device_queue WHERE device_id = ?",
        deviceId
      )
      .one()
  ).then((row) => row.count)

export const withHubSql = async <Result>(
  token: string,
  run: (sql: SqlStorage) => Result
): Promise<Result> =>
  runInDurableObject(await hubStub(token), (_hub, state) => run(state.storage.sql))

const InboxItemFrameBody = z.object({
  t: z.literal("inbox-item"),
  itemId: z.string(),
  kind: z.literal("webhook"),
  sender: z.string(),
  ephemeralKey: z.string(),
  sealed: z.string()
})

const decodeInboxHubFrame = (raw: string): InboxHubFrame => {
  const parsed = InboxItemFrameBody.safeParse(JSON.parse(raw))
  if (parsed.success) return parsed.data
  return decodeHubToMachine(raw)
}
