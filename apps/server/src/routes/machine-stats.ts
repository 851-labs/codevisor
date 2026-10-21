import type { IncomingMessage, ServerResponse } from "node:http"

import { HttpFailure, writeJson, type CodevisorServerServices } from "../server-context.js"

export const routeMachineStats = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/machine/stats" || request.method !== "GET") return false
  const sampler = services.machineStats
  if (sampler === undefined) throw new HttpFailure(501, "Machine stats unavailable")
  writeJson(response, 200, await sampler.read())
  return true
}
