import type { IncomingMessage, ServerResponse } from "node:http"

import type { SessionAutoResume } from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { matchRoute, run, writeJson, type RouteState } from "../server-context.js"

export const routeAutoResume = async (
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id/auto-resume")
  if (sessionId === undefined || request.method !== "DELETE") return false

  await routeState.autoResume?.cancel(sessionId)
  writeJson(response, 204, undefined)
  return true
}

export const withAutoResume = async <T extends object>(
  db: CodevisorDatabaseService,
  snapshot: T,
  sessionId: string
): Promise<T & { readonly autoResume?: SessionAutoResume }> => {
  const resume = await run(db.getAutoResume(sessionId))
  if (resume?.state !== "waiting") return snapshot

  const autoResume = resume.resetsAt === undefined ? {} : { resumesAt: resume.resetsAt }
  return { ...snapshot, autoResume }
}
