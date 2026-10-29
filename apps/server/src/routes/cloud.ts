import type { IncomingMessage, ServerResponse } from "node:http"

import { HttpFailure, readJson, writeJson, type CodevisorServerConfig } from "../server-context.js"
import { field } from "../unknown-values.js"

const isManagedBy = (value: unknown): value is "app" | "external" =>
  value === "app" || value === "external"

const cloudCredentials = (
  body: unknown
):
  | { readonly inviteCode: string }
  | { readonly serverUrl: string; readonly sessionToken: string }
  | undefined => {
  const inviteCode = field(body, "inviteCode")
  if (typeof inviteCode === "string") return { inviteCode }
  const serverUrl = field(body, "serverUrl")
  const sessionToken = field(body, "sessionToken")
  return typeof serverUrl === "string" && typeof sessionToken === "string"
    ? { serverUrl, sessionToken }
    : undefined
}

export const liveCloudDeviceId = (config: CodevisorServerConfig): string | undefined =>
  config.cloud === undefined ? config.cloudDeviceId : config.cloud.deviceId()

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
    const deviceId = liveCloudDeviceId(config)
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
    const raw = await readJson(request)
    const body = {
      managedBy: field(raw, "managedBy"),
      machineName: field(raw, "machineName")
    }
    const credentials = cloudCredentials(raw)
    if (credentials === undefined) {
      throw new HttpFailure(400, "serverUrl and sessionToken (or inviteCode) are required")
    }
    if ("inviteCode" in credentials && control.connectWithInvite === undefined) {
      throw new HttpFailure(501, "This server cannot join an account with an invite")
    }
    if (body.managedBy !== undefined && !isManagedBy(body.managedBy)) {
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
    const registration = {
      ...(body.managedBy === undefined ? {} : { managedBy: body.managedBy }),
      ...(body.machineName === undefined ? {} : { machineName: body.machineName.trim() })
    }
    let deviceId: string
    try {
      if ("inviteCode" in credentials) {
        deviceId = await control.connectWithInvite!(credentials.inviteCode, registration)
      } else {
        deviceId = await control.connect(
          credentials.serverUrl,
          credentials.sessionToken,
          registration
        )
      }
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
    const { removedFromAccount } = await control.disconnect()
    writeJson(response, 200, {
      ok: true,
      removedFromAccount,
      ...(removedFromAccount
        ? {}
        : {
            warning:
              "Codevisor Cloud could not be reached, so this machine is still listed on your account. Remove it from the machine list in the Codevisor app."
          })
    })
    return true
  }
  if (request.method === "PUT" && url.pathname === "/v1/cloud/direct-paths") {
    if (control?.setDirectPaths === undefined) {
      throw new HttpFailure(501, "This server cannot change its tunnel paths")
    }
    const allowed = field(await readJson(request), "allowed")
    if (typeof allowed !== "boolean") throw new HttpFailure(400, "allowed must be a boolean")
    const pathPolicy = control.setDirectPaths(allowed)
    writeJson(response, 200, pathPolicy === undefined ? {} : { pathPolicy })
    return true
  }
  throw new HttpFailure(404, "Cloud route not found")
}
