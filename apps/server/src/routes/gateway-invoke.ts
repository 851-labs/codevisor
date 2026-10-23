import type { IncomingMessage, ServerResponse } from "node:http"

import { FLEET_SESSION_EVENT_PATH } from "@codevisor/api"
import type { GatewayOrigin } from "@codevisor/mcp"

import {
  failureMessage,
  HttpFailure,
  readJson,
  writeJson,
  type CodevisorServerServices,
  type RouteState
} from "../server-context.js"
import { fleetCall, invokeForFleet } from "./fleet-calls.js"
import { receiveSessionEvent } from "./fleet-session-events.js"
import { routeMachineEnrollment } from "./machines.js"

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const optionalString = (value: unknown): value is string | undefined =>
  value === undefined || typeof value === "string"

const parseOrigin = (value: unknown): GatewayOrigin | undefined => {
  if (!isRecord(value)) return undefined
  const { machineId, machineName, ...rest } = value
  if (typeof machineId !== "string" || machineId === "" || typeof machineName !== "string") {
    return undefined
  }
  if (!OPTIONAL_ORIGIN_FIELDS.every((field) => optionalString(rest[field]))) return undefined
  const optional = OPTIONAL_ORIGIN_FIELDS.filter((field) => rest[field] !== undefined).map(
    (field) => [field, rest[field]]
  )
  return { machineId, machineName, ...Object.fromEntries(optional) }
}

const OPTIONAL_ORIGIN_FIELDS = [
  "sessionId",
  "sessionTitle",
  "clientId",
  "botId",
  "botMachineId"
] as const

const writeError = (
  response: ServerResponse,
  status: number,
  error: { message: string; code?: unknown; details?: unknown }
): void => {
  writeJson(response, status, {
    error: {
      message: error.message,
      ...(typeof error.code === "string" ? { code: error.code } : {}),
      ...(isRecord(error.details) ? { details: error.details } : {})
    }
  })
}

export const routeGatewayInvoke = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/machines") {
    if (services.machines === undefined) throw new HttpFailure(501, "Machines unavailable")
    writeJson(response, 200, { machines: await services.machines.list() })
    return true
  }
  if (await routeMachineEnrollment(services, request, response, url)) return true
  if (request.method !== "POST" || url.pathname !== "/v1/gateway/invoke") return false
  const mcp = services.mcp
  if (mcp === undefined) {
    writeError(response, 501, { message: "This machine has no MCP gateway" })
    return true
  }
  const body = await readJson(request).catch(() => undefined)
  const origin = isRecord(body) ? parseOrigin(body.origin) : undefined
  if (!isRecord(body) || typeof body.path !== "string" || body.path === "" || !origin) {
    writeError(response, 400, {
      message: "Expected { path, args, origin: { machineId, machineName } }"
    })
    return true
  }
  const path = body.path
  const call = fleetCall(services, request, origin)
  if (path === FLEET_SESSION_EVENT_PATH) {
    await receiveSessionEvent(services, routeState, call, body.args)
    writeJson(response, 200, { result: null })
    return true
  }
  const controller = new AbortController()
  response.once("close", () => {
    if (!response.writableFinished) controller.abort(new Error("the calling machine cancelled"))
  })
  try {
    const result = await invokeForFleet(services, call.origin, (botLink) =>
      mcp.invokeRemoteGatewayCall(call.origin, path, body.args, {
        signal: controller.signal,
        ...(botLink === undefined ? {} : { botLink })
      })
    )
    writeJson(response, 200, { result: result ?? null })
  } catch (cause) {
    const failure = isRecord(cause) ? cause : {}
    writeError(
      response,
      cause instanceof Error && cause.name === "CodeExecutionToolError" ? 422 : 500,
      {
        message: failureMessage(cause),
        code: failure.code,
        details: failure.details
      }
    )
  }
  return true
}
