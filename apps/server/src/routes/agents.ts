import {
  AgentItemKind,
  type AgentStatus,
  type SessionSummary,
  type TranscriptPage
} from "@codevisor/api"
import { Schema } from "effect"

import { HttpFailure, matchRoute, matchRouteParams, run, writeJson } from "../server-context.js"
import {
  defaultSearchLast,
  maxSearchLast,
  readAgentItem,
  searchAgentTranscript
} from "./agent-debug.js"
import { archiveAgent, listAgents, waitForAgents } from "./agent-lifecycle.js"
import { agentState } from "./agent-state.js"
import { rejectSyncThrows, type RouteContext } from "./route-context.js"
import { routeParam } from "./route-params.js"
import { finalAssistantText } from "./session-event-router.js"
import { findSession } from "./session-workspace.js"

export const routeAgents = (route: RouteContext): Promise<boolean> =>
  rejectSyncThrows(() => dispatchAgentRoute(route))

const dispatchAgentRoute = (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  if (request.method === "GET" && url.pathname === "/v1/agents") return listAgents(route)
  if (request.method === "POST" && url.pathname === "/v1/agents/wait") return waitForAgents(route)

  const archiveId = matchRoute(url.pathname, "/v1/agents/:id/archive")
  if (archiveId !== undefined && request.method === "POST") return archiveAgent(route, archiveId)
  if (request.method !== "GET") return Promise.resolve(false)

  const statusId = matchRoute(url.pathname, "/v1/agents/:id")
  if (statusId !== undefined) return readStatus(route, statusId)

  const searchId = matchRoute(url.pathname, "/v1/agents/:id/search")
  if (searchId !== undefined) return search(route, searchId)

  const itemRoute = matchRouteParams(url.pathname, "/v1/agents/:id/items/:itemId")
  if (itemRoute !== undefined)
    return readItem(route, routeParam(itemRoute, "id"), routeParam(itemRoute, "itemId"))

  return Promise.resolve(false)
}

const readStatus = async (
  { services, response }: RouteContext,
  agentId: string
): Promise<boolean> => {
  const session = await knownAgent(services.db, agentId)
  const page = await run(services.db.getTranscriptPage(agentId, undefined, 1))
  writeJson(response, 200, await agentStatus(services, session, page))
  return true
}

const search = async (
  { services, response, url }: RouteContext,
  agentId: string
): Promise<boolean> => {
  await knownAgent(services.db, agentId)
  const result = await searchAgentTranscript(services.db, agentId, {
    query: nonEmpty(url.searchParams.get("query")),
    kinds: searchKinds(url.searchParams.get("kinds")),
    tool: nonEmpty(url.searchParams.get("tool")),
    last: searchLast(url.searchParams.get("last")),
    next: nonEmpty(url.searchParams.get("next"))
  })
  writeJson(response, 200, result)
  return true
}

const readItem = async (
  { services, response }: RouteContext,
  agentId: string,
  itemId: string
): Promise<boolean> => {
  await knownAgent(services.db, agentId)
  writeJson(response, 200, await readAgentItem(services.db, agentId, itemId))
  return true
}

const agentStatus = async (
  services: RouteContext["services"],
  session: SessionSummary,
  page: TranscriptPage
): Promise<AgentStatus> =>
  agentStatusOf(session, page, await finalAssistantText(services, session.id))

export const agentStatusOf = (
  session: SessionSummary,
  page: Pick<TranscriptPage, "pendingQuestion" | "backgroundTasks">,
  lastReply: string
): AgentStatus => ({
  agentId: session.id,
  title: session.title,
  state: agentState(session, page),
  ...(lastReply.length === 0 ? {} : { lastReply }),
  ...(page.pendingQuestion === undefined ? {} : { pendingQuestion: page.pendingQuestion })
})

const knownAgent = async (
  db: RouteContext["services"]["db"],
  agentId: string
): Promise<SessionSummary> => {
  const session = await findSession(db, agentId)
  if (session === undefined) throw new HttpFailure(404, `Agent not found: ${agentId}`)
  return session
}

const isAgentItemKind = Schema.is(AgentItemKind)

const searchKinds = (raw: string | null): ReadonlySet<AgentItemKind> | undefined => {
  const kinds = (raw ?? "")
    .split(",")
    .map((kind) => kind.trim())
    .filter((kind) => kind.length > 0)
  if (kinds.length === 0) return undefined
  const unknown = kinds.filter((kind) => !isAgentItemKind(kind))
  if (unknown.length > 0) throw new HttpFailure(400, `Unknown kinds: ${unknown.join(", ")}`)
  return new Set(kinds.filter(isAgentItemKind))
}

const searchLast = (raw: string | null): number => {
  if (raw === null || raw.length === 0) return defaultSearchLast
  const last = Number(raw)
  if (!Number.isSafeInteger(last) || last < 1)
    throw new HttpFailure(400, "last must be a positive integer")
  return Math.min(last, maxSearchLast)
}

const nonEmpty = (value: string | null): string | undefined => {
  if (value === null || value.length === 0) return undefined
  return value
}
