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

export const session = (id: string, overrides: Record<string, unknown> = {}) => ({
  id,
  projectId: "project-1",
  serverId: "server",
  harnessId: "claude-code",
  title: `Agent ${id}`,
  origin: "codevisor",
  createdAt: "2026-10-23T00:00:00.000Z",
  ...overrides
})

export const caller = session("caller", {
  workspaceId: "caller-workspace",
  worktreeName: "caller-tree",
  configSelections: { model: "opus", reasoning: "high" }
})

export const projects = [
  {
    id: "project-1",
    name: "Codevisor",
    origin: "codevisor",
    createdAt: "2026-10-23T00:00:00.000Z",
    locations: []
  }
]

export const jsonResponse = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } })

export interface FakeOptions {
  readonly bare?: boolean
  readonly projects?: ReadonlyArray<unknown>
}

export const fakeServer = (
  sessions: Record<string, unknown>,
  listed: ReadonlyArray<unknown> = [],
  options: FakeOptions = {}
) => {
  const requests: Array<Recorded> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: URL, init: RequestInit) => {
      const body: unknown = typeof init.body === "string" ? JSON.parse(init.body) : undefined
      const path = decodeURIComponent(input.pathname)
      const method = String(init.method)
      const query = Object.fromEntries(input.searchParams)
      requests.push({ method, path, query, body })
      return respond({ method, path, query, body }, sessions, listed, options)
    })
  )
  return requests
}

const respond = (
  { method, path, query, body }: Recorded,
  sessions: Record<string, unknown>,
  listed: ReadonlyArray<unknown>,
  options: FakeOptions
): Response => {
  const detail = /^\/v1\/sessions\/([^/]+)$/.exec(path)
  if (method === "GET" && detail !== null) {
    const found = sessions[detail[1]!]
    return found === undefined
      ? jsonResponse({ error: "Session not found" }, 404)
      : jsonResponse({ session: found })
  }
  if (method === "GET" && path === "/v1/projects") return jsonResponse(options.projects ?? projects)
  if (method === "GET" && path === "/v1/sessions") return jsonResponse(listed)
  if (method === "POST" && path.endsWith("/worktrees")) {
    return jsonResponse({
      id: "tree-1",
      projectId: "project-1",
      serverId: "server",
      name: "fix-login",
      branch: "codevisor/fix-login",
      path: "/tmp/fix-login",
      createdAt: "2026-10-23T00:00:00.000Z"
    })
  }
  if (method === "POST" && path === "/v1/sessions") {
    if (options.bare === true) return jsonResponse(session("child"), 201)
    return jsonResponse(
      session("child", { ...expectRecord(body, "session body"), id: "child" }),
      201
    )
  }
  if (method === "POST" && path.endsWith("/prompt")) {
    if (options.bare === true) return jsonResponse({ accepted: true, sessionId: "child" })
    return jsonResponse({ accepted: true, sessionId: "child", delivered: "sent" })
  }
  if (path.includes("/subscriptions")) return subscriptionsResponse(method)
  if (method === "POST" && path === "/v1/sessions/wait") {
    return jsonResponse({
      sessions: [
        { id: "a", sidebarState: "inProgress" },
        { id: "b", sidebarState: "idle", actionRequiredKind: "question", pendingQuestion: question }
      ],
      timedOut: false
    })
  }
  if (method === "GET" && path.endsWith("/transcript")) {
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
  return jsonResponse({})
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
export const remote: AutomationProviderContext = { sessionId: "remote:studio:caller" }

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
