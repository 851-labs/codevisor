import type { IncomingMessage, ServerResponse } from "node:http"

import { HttpFailure, readJson, writeJson, type CodevisorServerConfig } from "../server-context.js"

/// This machine's cloud device id: live (app-driven) registrations beat the
/// boot-time snapshot, so a connect/disconnect is reflected immediately.
export const liveCloudDeviceId = (config: CodevisorServerConfig): string | undefined =>
  config.cloud === undefined ? config.cloudDeviceId : config.cloud.deviceId()

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
    const body = (await readJson(request)) as {
      readonly serverUrl?: unknown
      readonly sessionToken?: unknown
      readonly inviteCode?: unknown
      readonly managedBy?: unknown
      readonly machineName?: unknown
    }
    const withInvite = typeof body.inviteCode === "string"
    if (
      !withInvite &&
      (typeof body.serverUrl !== "string" || typeof body.sessionToken !== "string")
    ) {
      throw new HttpFailure(400, "serverUrl and sessionToken (or inviteCode) are required")
    }
    if (withInvite && control.connectWithInvite === undefined) {
      throw new HttpFailure(501, "This server cannot join an account with an invite")
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
    const registration = {
      ...(body.managedBy === undefined ? {} : { managedBy: body.managedBy as "app" | "external" }),
      ...(body.machineName === undefined
        ? {}
        : { machineName: (body.machineName as string).trim() })
    }
    let deviceId: string
    try {
      deviceId = withInvite
        ? await control.connectWithInvite!(body.inviteCode as string, registration)
        : await control.connect(body.serverUrl as string, body.sessionToken as string, registration)
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
  throw new HttpFailure(404, "Cloud route not found")
}
