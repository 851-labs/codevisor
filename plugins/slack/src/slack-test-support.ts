import { accountMeta } from "@codevisor/plugin-kit"
import {
  anyResult,
  connectClient,
  manualClock,
  openStream
} from "@codevisor/plugin-kit/test-support"
import { onTestFinished } from "vitest"

import { type Fetch, slackApiUrl } from "./slack-api.js"
import { requiredUserScopes } from "./slack-check.js"
import type { LocalFile, SlackFiles } from "./slack-files.js"
import { createSlackServer } from "./slack-server.js"
import { slackSignature } from "./slack-signature.js"

export const userToken = "xoxp-1111-2222-test"
export const signingSecret = "0123456789abcdef0123456789abcdef"
export const teamId = "T0ACME00001"
export const teamUrl = "https://acme.slack.com/"

export const dana = {
  id: "U0DANA00001",
  name: "dana",
  real_name: "Dana Ruiz",
  profile: { display_name: "Dana" }
}
export const sam = {
  id: "U0SAM000001",
  name: "sam",
  real_name: "Sam Lee",
  tz: "America/New_York",
  profile: { display_name: "Sam", email: "sam@acme.com", title: "SRE" }
}

export const deployBot = {
  id: "U0DEPLOY001",
  name: "deploy",
  real_name: "Deploy Bot",
  is_bot: true,
  profile: { display_name: "Deploy" }
}

export const eng = { id: "C0ENG000001", name: "eng", is_private: false }
export const incidents = {
  id: "C0INC000001",
  name: "incidents",
  is_private: false,
  topic: { value: "Pager" }
}
export const samDm = { id: "D0SAM000001", is_im: true, user: sam.id }

export type SlackHandler = (params: Record<string, string>) => Record<string, unknown>

export interface SlackCall {
  method: string
  params: Record<string, string>
}

export interface FakeSlack {
  fetch: Fetch
  calls: Array<SlackCall>
  uploads: Array<Uint8Array>
  scopes: Array<string>
  on(method: string, handler: SlackHandler): void
  called(method: string): Array<Record<string, string>>
}

export const fakeSlack = (): FakeSlack => {
  const calls: Array<SlackCall> = []
  const uploads: Array<Uint8Array> = []
  const scopes = [...requiredUserScopes]
  const handlers = new Map<string, SlackHandler>(Object.entries(defaultHandlers))

  const api = async (method: string, request: Request): Promise<Response> => {
    if (request.headers.get("authorization") !== `Bearer ${userToken}`)
      return Response.json({ ok: false, error: "invalid_auth" })

    const params = Object.fromEntries(new URLSearchParams(await request.text()))
    calls.push({ method, params })
    const handler = handlers.get(method)
    if (handler === undefined) throw new Error(`Unexpected Slack method ${method}`)

    return Response.json(
      { ok: true, ...handler(params) },
      { headers: { "x-oauth-scopes": scopes.join(",") } }
    )
  }

  const fetcher: Fetch = async (url, init) => {
    const request = new Request(url, init)
    if (url.startsWith(slackApiUrl)) return api(url.slice(slackApiUrl.length), request)
    if (url.startsWith(fileDownloadUrl)) return new Response(fileText)
    if (url.startsWith(uploadUrl)) {
      uploads.push(new Uint8Array(await request.arrayBuffer()))
      return new Response("OK")
    }
    throw new Error(`Unexpected request to ${url}`)
  }

  return {
    fetch: fetcher,
    calls,
    uploads,
    scopes,
    on: (method, handler) => handlers.set(method, handler),
    called: (method) => calls.filter((call) => call.method === method).map((call) => call.params)
  }
}

export const fileDownloadUrl =
  "https://files.slack.com/files-pri/T0ACME00001-F0NOTES0001/download/notes.txt"
export const uploadUrl = "https://files.slack.com/upload/v1/abc"
export const fileText = "Rollout notes\n"

const people = [dana, sam, deployBot]
const conversations = [eng, incidents, samDm]

const defaultHandlers: Readonly<Record<string, SlackHandler>> = {
  "auth.test": () => ({
    url: teamUrl,
    team: "Acme",
    user: dana.name,
    team_id: teamId,
    user_id: dana.id
  }),
  "users.info": (params) => {
    const user = people.find((person) => person.id === params.user)
    return user === undefined ? { ok: false, error: "user_not_found" } : { user }
  },
  "users.list": () => ({ members: people }),
  "conversations.info": (params) => {
    const channel = conversations.find((conversation) => conversation.id === params.channel)
    return channel === undefined ? { ok: false, error: "channel_not_found" } : { channel }
  },
  "users.conversations": () => ({ channels: [eng, incidents] }),
  "conversations.open": () => ({ channel: { id: samDm.id } }),
  "chat.postMessage": (params) => ({ channel: params.channel, ts: "1731350000.000200" }),
  "chat.getPermalink": (params) => ({
    permalink: `${teamUrl}archives/${params.channel}/p${params.message_ts?.replace(".", "")}`
  })
}

export const memoryFiles = (): SlackFiles & {
  saved: Map<string, Uint8Array>
  local: Map<string, LocalFile>
} => {
  const saved = new Map<string, Uint8Array>()
  const local = new Map<string, LocalFile>()
  return {
    saved,
    local,
    save: async (fileId, name, bytes) => {
      const path = `/tmp/codevisor-slack/${fileId}/${name}`
      saved.set(path, bytes)
      return path
    },
    read: async (path) => {
      const file = local.get(path)
      if (file === undefined) throw new Error(`ENOENT: ${path}`)
      return file
    }
  }
}

export const slackAccountMeta = (
  fields: Record<string, unknown> = { userToken, signingSecret }
) => ({
  [accountMeta]: { id: "acct-1", label: "Acme", fields }
})

export const connectSlack = async () => {
  const slack = fakeSlack()
  const files = memoryFiles()
  const clock = manualClock()
  const connected = await connectClient(createSlackServer({ fetch: slack.fetch, clock, files }))
  onTestFinished(() => connected.client.close())
  return { ...connected, slack, files, clock }
}

export type ConnectedSlack = Awaited<ReturnType<typeof connectSlack>>

export const callSlackTool = (
  connected: ConnectedSlack,
  name: string,
  args: Record<string, unknown>
) => connected.client.callTool({ name, arguments: args, _meta: slackAccountMeta() })

export const openSlackStream = (connected: ConnectedSlack, name: string) =>
  openStream(connected, { name, arguments: {}, cursor: null, _meta: slackAccountMeta() })

export const receivedAt = "2026-11-11T20:00:00.000Z"

export interface SignedOptions {
  secret?: string
  timestamp?: number
  receivedAt?: string
}

export const signedWebhook = (payload: Record<string, unknown>, options: SignedOptions = {}) => {
  const body = JSON.stringify(payload)
  const timestamp = options.timestamp ?? Date.parse(receivedAt) / millisecondsPerSecond
  return {
    ingress: "slack",
    request: {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-slack-request-timestamp": String(timestamp),
        "x-slack-signature": slackSignature(options.secret ?? signingSecret, timestamp, body)
      },
      body: Buffer.from(body).toString("base64"),
      receivedAt: options.receivedAt ?? receivedAt
    }
  }
}

export const eventCallback = (event: Record<string, unknown>, team = teamId) => ({
  type: "event_callback",
  team_id: team,
  event_id: "Ev0001",
  event
})

export const deliver = (connected: ConnectedSlack, webhook: ReturnType<typeof signedWebhook>) =>
  connected.client.request(
    { method: "codevisor/webhook", params: { ...webhook, _meta: slackAccountMeta() } },
    anyResult
  )

const millisecondsPerSecond = 1000
