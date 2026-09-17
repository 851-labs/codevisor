import type { IncomingMessage, ServerResponse } from "node:http"

import { HttpFailure, readJson, writeJson, type CodevisorServerConfig } from "../server-context.js"

/// The server owns cloud credentials and relay lifecycle for both the native
/// app and CLI. Callers never need to infer the server's data directory.
export const routeCloud = async (
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/cloud" && !url.pathname.startsWith("/v1/cloud/")) {
    return false
  }
  const control = config.cloud
  if (request.method === "GET" && url.pathname === "/v1/cloud") {
    const deviceId = control === undefined ? config.cloudDeviceId : control.deviceId()
    const state = control?.state()
    const managedBy = control?.managedBy()
    const serverUrl = control?.serverUrl?.()
    writeJson(response, 200, {
      connected: deviceId !== undefined,
      ...(deviceId === undefined ? {} : { deviceId }),
      ...(state === undefined ? {} : { state }),
      ...(serverUrl === undefined ? {} : { serverUrl }),
      ...(managedBy === undefined ? {} : { managedBy })
    })
    return true
  }
  if (request.method === "POST" && url.pathname === "/v1/cloud/connect") {
    if (control === undefined) {
      throw new HttpFailure(501, "This server cannot manage its cloud connection")
    }
    const body = (await readJson(request)) as {
      readonly serverUrl?: unknown
      readonly sessionToken?: unknown
      readonly managedBy?: unknown
      readonly machineName?: unknown
    }
    if (typeof body.serverUrl !== "string" || typeof body.sessionToken !== "string") {
      throw new HttpFailure(400, "serverUrl and sessionToken are required")
    }
    if (body.managedBy !== undefined && body.managedBy !== "app" && body.managedBy !== "external") {
      throw new HttpFailure(400, "managedBy must be app or external")
    }
    if (
      body.machineName !== undefined &&
      (typeof body.machineName !== "string" ||
        body.machineName.trim().length === 0 ||
        body.machineName.length > 120)
    ) {
      throw new HttpFailure(400, "machineName must contain 1 to 120 characters")
    }
    let deviceId: string
    try {
      deviceId = await control.connect(body.serverUrl, body.sessionToken, {
        ...(body.managedBy === undefined ? {} : { managedBy: body.managedBy }),
        ...(body.machineName === undefined
          ? {}
          : { machineName: (body.machineName as string).trim() })
      })
    } catch (cause) {
      throw new HttpFailure(
        502,
        `Cloud connect failed: ${cause instanceof Error ? cause.message : String(cause)}`
      )
    }
    writeJson(response, 200, { deviceId })
    return true
  }
  if (request.method === "POST" && url.pathname === "/v1/cloud/disconnect") {
    if (control === undefined) {
      throw new HttpFailure(501, "This server cannot manage its cloud connection")
    }
    await control.disconnect()
    writeJson(response, 200, { ok: true })
    return true
  }
  throw new HttpFailure(404, "Cloud route not found")
}
