import type { IncomingMessage, ServerResponse } from "node:http"

import {
  failureMessage,
  HttpFailure,
  readJson,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

/// The machines surface: GET /v1/machines lists every machine on the
/// account (this one, cloud presence, FleetRoster routes), and
/// POST /v1/gateway/invoke is the target end of a cross-machine gateway call
/// — another machine's sandbox reaching this machine's tools, over a direct
/// route (bearer token) or a sealed relay "gateway" channel (loopback).
///
/// Invoke answers `{ result }`, or `{ error: { message, code?, details? } }`:
/// 400 for a malformed call, 422 when the tool call itself failed, 501 when
/// this server has no gateway, 500 otherwise.

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const optionalString = (value: unknown): value is string | undefined =>
  value === undefined || typeof value === "string"

/// The decoded origin, with absent fields omitted (the gateway's GatewayOrigin
/// is exact about optional properties; the api schema is not).
interface GatewayCallOrigin {
  readonly machineId: string
  readonly machineName: string
  readonly sessionId?: string
  readonly sessionTitle?: string
  readonly clientId?: string
}

const parseOrigin = (value: unknown): GatewayCallOrigin | undefined => {
  if (!isRecord(value)) return undefined
  const { machineId, machineName, sessionId, sessionTitle, clientId } = value
  if (typeof machineId !== "string" || machineId === "" || typeof machineName !== "string") {
    return undefined
  }
  if (!optionalString(sessionId) || !optionalString(sessionTitle) || !optionalString(clientId)) {
    return undefined
  }
  return {
    machineId,
    machineName,
    ...(sessionId === undefined ? {} : { sessionId }),
    ...(sessionTitle === undefined ? {} : { sessionTitle }),
    ...(clientId === undefined ? {} : { clientId })
  }
}

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
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/machines") {
    if (services.machines === undefined) throw new HttpFailure(501, "Machines unavailable")
    writeJson(response, 200, { machines: await services.machines.list() })
    return true
  }
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
  // The caller hanging up (its sandbox aborted, or the relay channel was
  // cancelled) cancels the call here too.
  const controller = new AbortController()
  response.once("close", () => {
    if (!response.writableFinished) controller.abort(new Error("the calling machine cancelled"))
  })
  try {
    const result = await mcp.invokeRemoteGatewayCall(
      origin,
      body.path,
      body.args,
      controller.signal
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
