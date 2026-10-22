import type { IncomingMessage, ServerResponse } from "node:http"

import { readFirstRunStatus } from "../first-run-status.js"
import { writeJson, type CodevisorServerServices } from "../server-context.js"

export const routeFirstRun = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/first-run" || request.method !== "GET") return false
  writeJson(response, 200, await readFirstRunStatus(services))
  return true
}
