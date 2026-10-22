import type { ServerResponse } from "node:http"

import { run, writeJson } from "../server-context.js"
import type { CodevisorServerServices } from "../server-context.js"

export const writeIdempotentAction = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  sessionId: string,
  actionKind: string,
  payload: { readonly clientActionId?: string | undefined },
  runAction: () => Promise<unknown>
): Promise<void> => {
  if (payload.clientActionId !== undefined) {
    const existing = await savedActionResult(services, sessionId, payload.clientActionId)
    if (existing !== undefined) {
      writeJson(response, 202, existing)
      return
    }
  }

  const result = await runAction()
  if (payload.clientActionId !== undefined) {
    await saveActionResult(services, sessionId, payload.clientActionId, actionKind, result)
  }
  writeJson(response, 202, result)
}

export const savedActionResult = (
  services: CodevisorServerServices,
  sessionId: string,
  clientActionId: string
): Promise<unknown> => run(services.db.getSessionActionResult(sessionId, clientActionId))

export const saveActionResult = (
  services: CodevisorServerServices,
  sessionId: string,
  clientActionId: string,
  actionKind: string,
  result: unknown
): Promise<unknown> =>
  run(services.db.saveSessionActionResult(sessionId, clientActionId, actionKind, result))
