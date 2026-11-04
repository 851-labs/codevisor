import { accountMeta, ingressMeta } from "@codevisor/plugin-kit"
import { connectClient, manualClock, openStream } from "@codevisor/plugin-kit/test-support"
import { Server, WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/server"
import { onTestFinished } from "vitest"
import { z } from "zod"

import type { Fetch, LinearComment, LinearIssue, LinearPerson, LinearState } from "./linear-api.js"
import { linearGraphqlUrl, linearRevokeUrl } from "./linear-api.js"
import { linearMcpUrl } from "./linear-mcp.js"
import { createLinearServer } from "./linear-server.js"

export const linearToken = "lin_oauth_test_token"
export const organizationId = "org-acme"
export const me: LinearPerson = { id: "user-me", name: "Dana", email: "dana@acme.com" }
export const sam: LinearPerson = { id: "user-sam", name: "Sam", email: "sam@acme.com" }
export const meUrl = "https://linear.app/acme/profiles/dana"
export const todo: LinearState = { id: "state-todo", name: "Todo", type: "unstarted" }
export const done: LinearState = { id: "state-done", name: "Done", type: "completed" }

export interface FakeLinear {
  fetch: Fetch
  issues: Map<string, LinearIssue>
  comments: Map<string, LinearComment>
  graphqlCalls: Array<string>
  mcpCalls: Array<{ name: string; arguments: unknown }>
  revoked: Array<string>
  failGraphql(status: number): void
}

export const fakeIssue = (overrides: Partial<LinearIssue> = {}): LinearIssue => ({
  id: "issue-1",
  identifier: "ENG-1",
  title: "Launch checklist",
  url: "https://linear.app/acme/issue/ENG-1/launch-checklist",
  description: "",
  priority: 2,
  priorityLabel: "High",
  createdAt: "2026-11-04T19:00:00.000Z",
  updatedAt: "2026-11-04T20:00:00.000Z",
  state: done,
  team: { id: "team-eng", key: "ENG", name: "Engineering" },
  project: { id: "project-1", name: "Launch" },
  assignee: me,
  creator: sam,
  labels: { nodes: [{ name: "Bug" }] },
  ...overrides
})

export const fakeLinear = (): FakeLinear => {
  const issues = new Map<string, LinearIssue>()
  const comments = new Map<string, LinearComment>()
  const graphqlCalls: Array<string> = []
  const mcpCalls: FakeLinear["mcpCalls"] = []
  const revoked: Array<string> = []
  let failure: number | undefined

  const graphql = (request: Request, body: GraphqlBody): Response => {
    if (request.headers.get("authorization") !== `Bearer ${linearToken}`)
      return Response.json(
        {
          errors: [
            { message: "Authentication required", extensions: { type: "authentication error" } }
          ]
        },
        { status: 400 }
      )
    if (failure !== undefined)
      return Response.json({ errors: [{ message: "Down" }] }, { status: failure })

    const operation = /query (\w+)/.exec(body.query)?.[1] ?? ""
    graphqlCalls.push(operation)
    return answer(operation, body.variables?.id ?? "", { issues, comments })
  }

  const fetcher: Fetch = async (url, init) => {
    const request = new Request(url, init)
    if (url === linearGraphqlUrl) return graphql(request, graphqlBody.parse(await request.json()))
    if (url === linearRevokeUrl) {
      revoked.push(new URLSearchParams(await request.text()).get("token") ?? "")
      return new Response(null, { status: 200 })
    }
    if (url === linearMcpUrl) return linearMcp(request, mcpCalls)
    throw new Error(`Unexpected request to ${url}`)
  }

  return {
    fetch: fetcher,
    issues,
    comments,
    graphqlCalls,
    mcpCalls,
    revoked,
    failGraphql: (status) => {
      failure = status
    }
  }
}

export const accountFor = (accessToken = linearToken) => ({
  [accountMeta]: { id: "acct-1", label: "Acme", identity: me.email, accessToken, fields: {} }
})

export const routedMeta = (accessToken = linearToken) => ({
  ...accountFor(accessToken),
  [ingressMeta]: {
    ingress: [{ name: "linear", url: "https://hooks.example/i/abc", route: { name: "linear" } }]
  }
})

export const connectLinear = async () => {
  const linear = fakeLinear()
  const clock = manualClock()
  const connected = await connectClient(createLinearServer({ fetch: linear.fetch, clock }))
  onTestFinished(() => connected.client.close())
  return { ...connected, linear, clock }
}

export type ConnectedLinear = Awaited<ReturnType<typeof connectLinear>>

export const openLinearStream = (connected: ConnectedLinear, name: string) =>
  openStream(connected, { name, arguments: {}, cursor: null, _meta: routedMeta() })

export const ping = (overrides: Record<string, unknown>) => ({
  ingress: "linear",
  request: {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: Buffer.from(
      JSON.stringify({ organizationId, createdAt: "2026-11-04T20:00:00.000Z", ...overrides })
    ).toString("base64"),
    receivedAt: "2026-11-04T20:00:01.000Z"
  },
  _meta: accountFor()
})

const graphqlBody = z.object({
  query: z.string(),
  variables: z.object({ id: z.string().optional() }).optional()
})

type GraphqlBody = z.infer<typeof graphqlBody>

interface Store {
  issues: Map<string, LinearIssue>
  comments: Map<string, LinearComment>
}

const people = new Map([me, sam].map((person) => [person.id, person]))
const states = new Map([todo, done].map((state) => [state.id, state]))

const answer = (operation: string, id: string, store: Store): Response => {
  if (operation === "Viewer")
    return Response.json({
      data: {
        viewer: {
          ...me,
          url: meUrl,
          organization: { id: organizationId, name: "Acme", urlKey: "acme" }
        }
      }
    })
  const found = lookups[operation]?.(id, store)
  if (found === undefined)
    return Response.json({ data: null, errors: [{ message: "Entity not found: Issue" }] })

  return Response.json({ data: found })
}

const lookups: Record<string, (id: string, store: Store) => Record<string, unknown> | undefined> = {
  Issue: (id, store) => present("issue", store.issues.get(id)),
  Comment: (id, store) => present("comment", store.comments.get(id)),
  State: (id) => present("workflowState", states.get(id)),
  User: (id) => present("user", people.get(id))
}

const present = (key: string, value: unknown) =>
  value === undefined ? undefined : { [key]: value }

const linearMcp = async (request: Request, calls: FakeLinear["mcpCalls"]): Promise<Response> => {
  if (request.headers.get("authorization") !== `Bearer ${linearToken}`)
    return Response.json({ error: "invalid_token" }, { status: 401 })

  const server = new Server({ name: "linear", version: "1.0.0" }, { capabilities: { tools: {} } })
  server.setRequestHandler("tools/list", () => ({ tools: [] }))
  server.setRequestHandler("tools/call", (call) => {
    calls.push({ name: call.params.name, arguments: call.params.arguments })
    return {
      content: [{ type: "text", text: `ran ${call.params.name}` }],
      structuredContent: { ok: true }
    }
  })
  const transport = new WebStandardStreamableHTTPServerTransport({ enableJsonResponse: true })
  await server.connect(transport)
  return transport.handleRequest(request)
}
