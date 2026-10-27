import { remoteSessionKey } from "@codevisor/api"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { vi } from "vitest"

import type { AutomationProviderContext } from "./automation-provider.js"
import { makeCodevisorProvider } from "./codevisor-provider.js"
import { expectArray, expectRecord, expectString } from "./unknown-values.js"

export interface Recorded {
  readonly method: string
  readonly path: string
  readonly query: Record<string, string>
  readonly body: unknown
}

export const jsonResponse = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })

export interface FakeOptions {
  readonly failing?: ReadonlyArray<string>
}

export const fakeServer = (listed: ReadonlyArray<unknown> = [], options: FakeOptions = {}) => {
  const requests: Array<Recorded> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: URL, init: RequestInit) => {
      const body: unknown = typeof init.body === "string" ? JSON.parse(init.body) : undefined
      const path = decodeURIComponent(input.pathname)
      const method = String(init.method)
      const query = Object.fromEntries(input.searchParams)
      requests.push({ method, path, query, body })
      return respond({ method, path, query, body }, listed, options)
    })
  )
  return requests
}

const respond = (
  { method, path, query }: Recorded,
  listed: ReadonlyArray<unknown>,
  options: FakeOptions
): Response => {
  if (options.failing?.includes(`${method} ${path}`) === true) {
    return jsonResponse({ error: `${method} ${path} broke` }, 500)
  }
  if (method === "GET" && path === "/v1/agents") return jsonResponse({ items: listed })
  if (method === "POST" && path === "/v1/agents/wait") {
    return jsonResponse({
      items: [
        { agentId: "a", state: "working" },
        { agentId: "b", state: "waitingForUser", pendingQuestion: question }
      ],
      timedOut: false
    })
  }
  const closed = /^\/v1\/agents\/([^/]+)\/close$/.exec(path)
  if (method === "POST" && closed !== null) {
    return jsonResponse({ agentId: closed[1], workspaceId: "caller-workspace", closed: true })
  }
  const archived = /^\/v1\/workspaces\/([^/]+)\/archive$/.exec(path)
  if (method === "POST" && archived !== null) {
    return jsonResponse({ workspaceId: archived[1], archived: true })
  }
  if (path.includes("/subscriptions")) return subscriptionsResponse(method)
  return jsonResponse({
    items: [{ id: "item-1", ...transcriptItem }],
    nextBefore: "older",
    hasNewer: false,
    hasMore: query.before !== "older",
    eventCursor: 1,
    stateUpdates: [],
    setupActivities: []
  })
}

export const transcriptItem = {
  sessionId: "child",
  sequence: 1,
  role: "assistant",
  text: "hi",
  createdAt: "2026-10-23T00:00:00.000Z",
  updatedAt: "2026-10-23T00:00:00.000Z",
  isGenerating: false,
  hasDetails: false,
  revision: 1
}

export const subscription = {
  id: "sub-1",
  subscriberSessionId: "caller",
  targetSessionId: "other",
  events: ["turn_ended"],
  once: true,
  createdAt: "2026-10-23T00:00:00.000Z"
}

const subscriptionsResponse = (method: string): Response => {
  if (method === "GET") return jsonResponse({ subscriptions: [subscription] })
  if (method === "DELETE") return new Response(null, { status: 204 })
  return jsonResponse(subscription, 201)
}

export const question = {
  sessionUpdate: "question",
  questionId: "q1",
  questions: [{ id: "q", question: "Ship it?", options: [], allowsOther: true }]
}

export const local: AutomationProviderContext = { sessionId: "caller", projectId: "project-1" }
export const remote: AutomationProviderContext = {
  sessionId: remoteSessionKey("studio", "caller")
}

const provider = makeCodevisorProvider(
  () => "http://127.0.0.1:43210",
  async () => "token"
)

export const call = async (
  context: AutomationProviderContext,
  name: string,
  args: Record<string, unknown>
): Promise<unknown> => {
  const result: CallToolResult = await provider.invoke(context, name, args)
  const parsed: unknown = JSON.parse(
    expectString(expectRecord(result.content[0], "content").text, "text")
  )
  return parsed
}

export const bodyOf = (requests: ReadonlyArray<Recorded>, method: string, path: string): unknown =>
  requests.find((request) => request.method === method && request.path === path)!.body

export const itemsOf = (value: unknown): ReadonlyArray<unknown> =>
  expectArray(expectRecord(value, "list result").items, "items")
