import type { IncomingMessage, ServerResponse } from "node:http"
import { HttpFailure, readJson, writeJson, type CodevisorServerConfig } from "../server-context.js"

/// Publishes `worktree.setup` progress events (subjectId = worktree id),
/// serialized on a promise chain so streamed log lines and lifecycle updates
/// land in the event log in emission order. Returned promises resolve once
/// that update is durable; failures surface to awaited call sites without
/// stalling later updates.
/// Directory listing for the remote project picker. Directories only —
/// choosing a project means choosing a folder — with a git badge so existing
/// checkouts stand out. Requires the caller's bearer token like every other
/// data route; the response deliberately exposes nothing but names.
/// This machine's cloud registration. The desktop app drives these after
/// account sign-in/sign-out so the local machine appears on (and leaves) the
/// user's Codevisor Cloud account without a separate `codevisor auth login`.
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
    writeJson(response, 200, {
      connected: deviceId !== undefined,
      ...(deviceId === undefined ? {} : { deviceId }),
      ...(state === undefined ? {} : { state }),
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
    }
    if (typeof body.serverUrl !== "string" || typeof body.sessionToken !== "string") {
      throw new HttpFailure(400, "serverUrl and sessionToken are required")
    }
    let deviceId: string
    try {
      deviceId = await control.connect(body.serverUrl, body.sessionToken)
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
