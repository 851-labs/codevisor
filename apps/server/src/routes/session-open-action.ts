import type { IncomingMessage, ServerResponse } from "node:http"

import { OpenSessionRequest as OpenSessionRequestSchema } from "@codevisor/api"
import type { OpenSessionRequest } from "@codevisor/api"

import { appendAndPublish, HttpFailure, readSchema, run, writeJson } from "../server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "../server-context.js"
import { applySessionUpdate, createSessionIfMissing, findSession } from "./session-workspace.js"
import { withUpdateGate } from "./update-gate.js"

export const openSessionAction = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  config: CodevisorServerConfig,
  openSessionId: string
): Promise<boolean> => {
  const payload = await readSchema(request, OpenSessionRequestSchema)
  const limit = admitOpenSession(payload, openSessionId)
  // Project: create-if-missing. An existing record is never updated from
  // the open snapshot — it may predate changes made elsewhere (archiving),
  // and opening a chat must not revert them.
  if (payload.project?.id !== undefined) {
    await ensureOpenProject(services, fanout, payload)
  }
  const existing = await findSession(services.db, openSessionId)
  const session =
    existing === undefined
      ? (
          await createSessionIfMissing(services, fanout, routeState, config, {
            ...payload.session,
            id: openSessionId
          })
        ).session
      : payload.update === undefined
        ? existing
        : await applySessionUpdate(services, fanout, openSessionId, payload.update)
  const transcript = withUpdateGate(
    await run(services.db.getTranscriptPage(openSessionId, undefined, limit)),
    services,
    routeState,
    openSessionId
  )
  const runtime = await run(services.db.getSessionRuntimeState(openSessionId))
  writeJson(response, 200, { session, transcript, runtime })
  return true
}

const admitOpenSession = (payload: OpenSessionRequest, openSessionId: string): number => {
  if (
    payload.session.id !== undefined &&
    payload.session.id.toLowerCase() !== openSessionId.toLowerCase()
  ) {
    throw new HttpFailure(400, "Session id in body does not match the path")
  }
  const limit = payload.transcriptLimit ?? 32
  if (!Number.isSafeInteger(limit) || limit < 1) {
    throw new HttpFailure(400, "Invalid transcript page limit")
  }
  return limit
}

const ensureOpenProject = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  payload: OpenSessionRequest
): Promise<void> => {
  const wanted = payload.project!.id!.toLowerCase()
  const exists = (await run(services.db.listProjects)).some(
    (candidate) => candidate.id.toLowerCase() === wanted
  )
  if (!exists) {
    const project = await run(services.db.createProject(payload.project!))
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
  }
}
