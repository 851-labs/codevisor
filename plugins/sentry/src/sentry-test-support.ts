import { accountMeta } from "@codevisor/plugin-kit"
import { connectClient, manualClock, openStream } from "@codevisor/plugin-kit/test-support"
import { Server, WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/server"
import { onTestFinished } from "vitest"

import type {
  Fetch,
  SentryActivity,
  SentryHosts,
  SentryIssue,
  SentryOrganization,
  SentryPerson
} from "./sentry-api.js"
import { createSentryServer } from "./sentry-server.js"

export const sentryToken = "sntryu_oauth_test_token"
export const hosts: SentryHosts = {
  apiUrl: "https://sentry.test",
  mcpUrl: "https://mcp.sentry.test/mcp"
}
export const me: SentryPerson = { id: "1", name: "Dana", email: "dana@acme.com" }
export const sam: SentryPerson = { id: "2", name: "Sam", email: "sam@acme.com" }
export const acme: SentryOrganization = {
  id: "101",
  slug: "acme",
  name: "Acme",
  links: { regionUrl: "https://us.sentry.test" }
}
export const globex: SentryOrganization = { id: "202", slug: "globex", name: "Globex", links: null }
export const myTeam = { id: "11", slug: "web", name: "Web" }
export const start = Date.parse("2026-11-25T12:00:00.000Z")

export interface FakeSentry {
  fetch: Fetch
  issues: Map<string, SentryIssue>
  searches: Array<string>
  mcpCalls: Array<{ name: string; arguments: unknown }>
  detailReads: Array<string>
}

export const fakeIssue = (overrides: Partial<SentryIssue> = {}): SentryIssue => ({
  id: "4242",
  shortId: "WEB-1Z",
  title: "TypeError: Cannot read properties of undefined (reading 'total')",
  culprit: "app/checkout.ts in submitOrder",
  level: "error",
  status: "unresolved",
  substatus: "new",
  permalink: "https://acme.sentry.io/issues/4242/",
  project: { id: "7", slug: "web", name: "Web" },
  firstSeen: new Date(start + 60_000).toISOString(),
  lastSeen: new Date(start + 60_000).toISOString(),
  count: 3,
  userCount: 2,
  assignedTo: null,
  activity: [],
  ...overrides
})

export const activity = (overrides: Partial<SentryActivity>): SentryActivity => ({
  id: "9001",
  type: "note",
  dateCreated: new Date(start + 60_000).toISOString(),
  user: sam,
  data: {},
  ...overrides
})

export const fakeSentry = (): FakeSentry => {
  const issues = new Map<string, SentryIssue>()
  const searches: Array<string> = []
  const mcpCalls: FakeSentry["mcpCalls"] = []
  const detailReads: Array<string> = []

  const rest = (url: URL): Response => {
    const route = restRoutes.find((candidate) => candidate.pattern.test(url.pathname))
    if (route === undefined) return Response.json({ detail: "Not found" }, { status: 404 })

    return route.answer(url, { issues, searches, detailReads })
  }

  const fetcher: Fetch = async (url, init) => {
    const request = new Request(url, init)
    if (url.startsWith(hosts.mcpUrl)) return sentryMcp(request, mcpCalls)
    if (request.headers.get("authorization") !== `Bearer ${sentryToken}`)
      return Response.json({ detail: "Invalid token" }, { status: 401 })

    return rest(new URL(url))
  }

  return { fetch: fetcher, issues, searches, mcpCalls, detailReads }
}

export const accountFor = (accessToken = sentryToken) => ({
  [accountMeta]: { id: "acct-1", label: "Dana", identity: me.email, accessToken, fields: {} }
})

export const connectSentry = async () => {
  const sentry = fakeSentry()
  const clock = manualClock(start)
  const server = createSentryServer({ fetch: sentry.fetch, clock, hosts })
  const connected = await connectClient(server)
  onTestFinished(() => connected.client.close())
  return { ...connected, sentry, clock }
}

export type ConnectedSentry = Awaited<ReturnType<typeof connectSentry>>

export const openSentryStream = (connected: ConnectedSentry, name: string) =>
  openStream(connected, { name, arguments: {}, cursor: null, _meta: accountFor() })

interface Store {
  issues: Map<string, SentryIssue>
  searches: Array<string>
  detailReads: Array<string>
}

interface RestRoute {
  pattern: RegExp
  answer(url: URL, store: Store): Response
}

const organizationsByRegion = new Map([
  [`${new URL(acme.links?.regionUrl ?? "").host}:acme`, acme],
  [`${new URL(hosts.apiUrl).host}:globex`, globex]
])

const organizationAt = (url: URL): SentryOrganization | undefined =>
  organizationsByRegion.get(`${url.host}:${url.pathname.split("/")[4] ?? ""}`)

const issuesIn = (url: URL, store: Store): Array<SentryIssue> =>
  organizationAt(url)?.id === acme.id ? [...store.issues.values()] : []

const restRoutes: ReadonlyArray<RestRoute> = [
  { pattern: /^\/api\/0\/users\/me\/$/, answer: () => Response.json(me) },
  { pattern: /^\/api\/0\/organizations\/$/, answer: () => Response.json([acme, globex]) },
  {
    pattern: /^\/api\/0\/organizations\/[\w-]+\/user-teams\/$/,
    answer: (url) => Response.json(organizationAt(url)?.id === acme.id ? [myTeam] : [])
  },
  {
    pattern: /^\/api\/0\/organizations\/[\w-]+\/issues\/$/,
    answer: (url, store) => {
      const query = url.searchParams.get("query") ?? ""
      store.searches.push(`${organizationAt(url)?.slug ?? "?"} ${query}`)
      return Response.json(issuesIn(url, store).filter((issue) => matches(issue, query)))
    }
  },
  {
    pattern: /^\/api\/0\/organizations\/[\w-]+\/issues\/\d+\/$/,
    answer: (url, store) => {
      const issueId = url.pathname.split("/")[6] ?? ""
      store.detailReads.push(issueId)
      const found = issuesIn(url, store).find((issue) => issue.id === issueId)
      return found === undefined
        ? Response.json({ detail: "Not found" }, { status: 404 })
        : Response.json(found)
    }
  }
]

const matches = (issue: SentryIssue, query: string): boolean => {
  const firstSeen = /firstSeen:>(\S+)/.exec(query)?.[1]
  const lastSeen = /lastSeen:>(\S+)/.exec(query)?.[1]
  const substatus = /is:(regressed|escalating)/.exec(query)?.[1]
  if (firstSeen !== undefined && !after(issue.firstSeen, firstSeen)) return false
  if (lastSeen !== undefined && !after(issue.lastSeen, lastSeen)) return false
  if (substatus !== undefined && issue.substatus !== substatus) return false
  if (query.includes("assigned:[me, my_teams]") && !assignedToMeOrMyTeam(issue)) return false

  return true
}

const after = (iso: string, sentryTime: string): boolean =>
  Date.parse(iso) > Date.parse(`${sentryTime}Z`)

const assignedToMeOrMyTeam = (issue: SentryIssue): boolean =>
  (issue.assignedTo?.type === "user" && issue.assignedTo.id === me.id) ||
  (issue.assignedTo?.type === "team" && issue.assignedTo.id === myTeam.id)

const sentryMcp = async (request: Request, calls: FakeSentry["mcpCalls"]): Promise<Response> => {
  if (request.headers.get("authorization") !== `Sentry-Bearer ${sentryToken}`)
    return Response.json({ error: "invalid_token" }, { status: 401 })

  const server = new Server({ name: "sentry", version: "1.0.0" }, { capabilities: { tools: {} } })
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
