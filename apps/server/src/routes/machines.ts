import type { IncomingMessage, ServerResponse } from "node:http"

import { AddMachineRequest as AddMachineRequestSchema } from "@codevisor/api"

import {
  HttpFailure,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

/// Adding and removing machines on the account — one route per operation,
/// shared by `codevisor machines …` and the `machines.*` agent tools:
/// - POST /v1/machines/invite → { code, expiresAt } (a one-time join code)
/// - POST /v1/machines/add { ssh, name?, sshPort? } → { machine }
/// - DELETE /v1/machines/:machineId → { machines } (the remaining list)
export const routeMachineEnrollment = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const invite = request.method === "POST" && url.pathname === "/v1/machines/invite"
  const add = request.method === "POST" && url.pathname === "/v1/machines/add"
  const removal =
    request.method === "DELETE" ? /^\/v1\/machines\/([^/]+)$/.exec(url.pathname) : null
  if (!invite && !add && removal === null) return false
  const enrollment = services.machineEnrollment
  if (enrollment === undefined) {
    throw new HttpFailure(501, "This server can't add or remove machines")
  }
  if (invite) {
    response.setHeader("Cache-Control", "no-store")
    writeJson(response, 201, await enrollment.invite())
    return true
  }
  if (add) {
    const body = await readSchema(request, AddMachineRequestSchema)
    // The caller hanging up cancels the install on the host.
    const controller = new AbortController()
    response.once("close", () => {
      if (!response.writableFinished) controller.abort(new Error("the caller cancelled"))
    })
    writeJson(response, 201, { machine: await enrollment.add(body, controller.signal) })
    return true
  }
  const machine = decodeURIComponent(removal![1]!)
  writeJson(response, 200, { machines: await enrollment.remove(machine) })
  return true
}
