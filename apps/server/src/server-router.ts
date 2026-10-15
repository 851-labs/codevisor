import type { IncomingMessage, ServerResponse } from "node:http"
import { hostname } from "node:os"

import { makeOpenApiDocument, MAX_UPLOAD_BYTES, RestartDrainRequest } from "@codevisor/api"
import type { RestartDrainRequest as RestartDrainRequestBody, UpdateInfo } from "@codevisor/api"
import type { ServerUpdateChannel } from "@codevisor/updater"

import { applyAfterDrain } from "./apply-after-drain.js"
import { routeBrowserState } from "./routes/browser-state.js"
import { routeBrowserUse } from "./routes/browser-use.js"
import { routeClientControl } from "./routes/client-control.js"
import { liveCloudDeviceId, routeCloud } from "./routes/cloud.js"
import { handleEvents } from "./routes/events.js"
import { routeFiles } from "./routes/files.js"
import { routeFs } from "./routes/fs.js"
import { routeGatewayInvoke } from "./routes/gateway-invoke.js"
import { discoverCapabilities, routeHarnesses } from "./routes/harnesses.js"
import { routeMachineMcps } from "./routes/mcp-machine.js"
import { routeMcps, routeMcpScopes, routeNativeMcps } from "./routes/mcps.js"
import { routeNetDirect } from "./routes/net-direct.js"
import { routePluginProxy, routePlugins } from "./routes/plugins.js"
import { routeProjects } from "./routes/projects.js"
import { routeScreenSharing } from "./routes/screen-sharing.js"
import { routeSessions } from "./routes/sessions.js"
import { routeSimulators, simulatorsAvailable } from "./routes/simulators.js"
import { routeSkills } from "./routes/skills.js"
import { configMutationNamespace, runBackgroundSyncReconcile } from "./routes/sync-reconcilers.js"
import { routeSync } from "./routes/sync.js"
import { routeTerminals } from "./routes/terminals.js"
import { routeToolIcons } from "./routes/tool-icons.js"
import { routeTranscriptStress } from "./routes/transcript-stress.js"
import { routeWorkspaces } from "./routes/workspaces.js"
import {
  appendAndPublish,
  authorize,
  failureMessage,
  HttpFailure,
  parseRequestUrl,
  readSchema,
  run,
  swallowError,
  writeFailure,
  writeJson
} from "./server-context.js"
import type {
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState
} from "./server-context.js"

export const handleRequest = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  try {
    if (isBrowserProxyRequest(request)) {
      if (routeState.browserProxy) routeState.browserProxy.handleHTTP(request, response)
      else response.writeHead(501).end()
      return
    }
    const url = parseRequestUrl(request)
    if (url.pathname === "/harness/provider-token") {
      if (!services.sharedAccounts) throw new HttpFailure(501, "Account gateway unavailable")
      await services.sharedAccounts.providers.runtime.handle(request, response)
      return
    }
    if (url.pathname.startsWith("/harness/claude/")) {
      if (!services.sharedAccounts) throw new HttpFailure(501, "Account gateway unavailable")
      await services.sharedAccounts.gateway.handle(request, response, url)
      return
    }
    const mutatedPlane = configMutationNamespace(request.method, url.pathname)
    if (mutatedPlane !== undefined) {
      response.once("finish", () => {
        if (response.statusCode < 400) {
          void runBackgroundSyncReconcile(services, config, fanout, mutatedPlane)
        }
      })
    }
    if (request.method === "GET" && url.pathname === "/v1/health") {
      writeJson(response, 200, {
        ok: true,
        version: config.version,
        database: "ready",
        bootId: config.bootId,
        processId: config.processId,
        appOwned: config.appOwned,
        buildNumber: config.buildNumber,
        sourceRevision: config.sourceRevision,
        serviceManaged: config.serviceManaged
      })
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/discovery") {
      writeJson(response, 200, {
        serverId: config.id,
        machineId: await run(services.db.getOrCreateInstanceId),
        name: config.name,
        kind: config.kind,
        version: config.version,
        platform: process.platform,
        hostname: hostname(),
        cloudLinked: liveCloudDeviceId(config) !== undefined
      })
      return
    }

    if (url.pathname === "/mcp/gateway") {
      if (services.mcp === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
      await services.mcp.handleGatewayRequest(request, response)
      return
    }

    if (url.pathname.startsWith("/v1/plugins/")) {
      if (await routePluginProxy(services, request, response, url)) {
        return
      }
    }

    if (request.method === "GET" && url.pathname === "/v1/mcps/oauth/callback") {
      if (services.mcp === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
      const state = url.searchParams.get("state")
      const code = url.searchParams.get("code")
      if (state === null || code === null) throw new HttpFailure(400, "Missing OAuth callback data")
      await services.mcp.finishOAuth(state, code)
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" })
      response.end(
        "<!doctype html><title>Codevisor</title><p>Authorization complete. Codevisor is connecting to the MCP server. You can close this window.</p>"
      )
      return
    }
    if (request.method === "GET" && url.pathname === "/v1/mcps/oauth/complete") {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" })
      response.end(
        "<!doctype html><title>Codevisor</title><p>Codevisor is reconnecting to the MCP server. You can close this window.</p>"
      )
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/navigation") {
      await authorize(services.db, config, request)
      writeJson(response, 200, await run(services.db.getNavigationSnapshot))
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/events") {
      await authorize(services.db, config, request)
      await handleEvents(services.db, fanout, url, response)
      return
    }

    await authorize(services.db, config, request)

    if (await routeTranscriptStress(services, fanout, routeState, request, response, url)) return

    if (await routeScreenSharing(services, config, request, response, url)) return
    if (await routeSimulators(config, request, response, url)) return

    if (await routeBrowserState(services, request, response, url)) return

    if (request.method === "POST" && url.pathname === "/v1/browser/proxy-session") {
      if (request.headers.origin !== undefined) throw new HttpFailure(403, "Native clients only")
      if (routeState.browserProxy === undefined)
        throw new HttpFailure(501, "Browser proxy unavailable")
      response.setHeader("Cache-Control", "no-store")
      writeJson(response, 201, routeState.browserProxy.session)
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/events/cursor") {
      writeJson(response, 200, { cursor: await run(services.db.latestEventCursor) })
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/info") {
      const cloudDeviceId = liveCloudDeviceId(config)
      writeJson(response, 200, {
        id: config.id,
        name: config.name,
        kind: config.kind,
        version: config.version,
        platform: process.platform,
        bindHost: config.host,
        features: [
          "browser-proxy-v1",
          "browser-http-proxy-v1",
          "browser-state-v1",
          ...(config.screenSharing === undefined
            ? []
            : ["screen-sharing-v1", "computer-use-stream-v1"]),
          ...(services.mcp === undefined ? [] : ["live-preview-v1"]),
          "canonical-chat-v1",
          "session-event-stream-v1",
          "transcript-pagination-v1",
          ...(services.plugins === undefined ? [] : ["plugins-v1"]),
          ...((await simulatorsAvailable(config)) ? ["simulator-v1"] : [])
        ],
        machineId: await run(services.db.getOrCreateInstanceId),
        arch: process.arch,
        hostname: hostname(),
        maxUploadBytes: MAX_UPLOAD_BYTES,
        ...(config.icon === undefined ? {} : { icon: config.icon }),
        ...(cloudDeviceId === undefined ? {} : { cloudDeviceId })
      })
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/openapi.json") {
      writeJson(response, 200, makeOpenApiDocument(config.version))
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/update") {
      if (config.updater !== undefined) {
        const force = url.searchParams.get("refresh") === "1"
        const channel = serverUpdateChannelFrom(url.searchParams.get("channel"))
        const info = withRestartDrain(routeState, await config.updater.check({ channel, force }))
        publishUpdateChanged(services, fanout, routeState, info)
        writeJson(response, 200, info)
        return
      }
      writeJson(response, 200, await run(services.db.getUpdateInfo))
      return
    }

    if (request.method === "POST" && url.pathname === "/v1/update/apply") {
      if (config.updater === undefined) {
        throw new HttpFailure(409, "This server does not support remote updates")
      }
      const busy =
        routeState.activePromptSessions.size > 0 || routeState.activeTurnSessions.size > 0
      if (busy && url.searchParams.get("whenBusy") === "refuse") {
        writeJson(response, 200, { accepted: false, reason: "busy" })
        return
      }
      const channel = serverUpdateChannelFrom(url.searchParams.get("channel"))
      const info = await config.updater.check({ channel, force: true })
      publishUpdateChanged(services, fanout, routeState, info)
      if (!info.updateAvailable) {
        writeJson(response, 200, { accepted: false, targetVersion: info.currentVersion })
        return
      }
      writeJson(response, 202, {
        accepted: true,
        targetVersion: info.latestVersion,
        ...(info.latestBuildNumber === undefined
          ? {}
          : { targetBuildNumber: info.latestBuildNumber }),
        draining: busy
      })
      const updater = config.updater
      void applyAfterDrain(
        routeState.restart,
        { interrupt: url.searchParams.get("interrupt") === "1" },
        () =>
          publishUpdateChanged(services, fanout, routeState, withRestartDrain(routeState, info)),
        () => updater.apply({ channel })
      ).catch(
        /* v8 ignore next */
        (cause: unknown) => console.log(`Update apply failed: ${failureMessage(cause)}`)
      )
      return
    }

    if (url.pathname === "/v1/restart/drain") {
      if (request.method === "GET") {
        writeJson(response, 200, routeState.restart.state())
        return
      }
      if (request.method === "POST") {
        const payload = await readSchema(request, RestartDrainRequest).catch(
          (): RestartDrainRequestBody => ({})
        )
        void routeState.restart
          .begin({ interrupt: payload.interrupt, timeoutMs: payload.timeoutMs })
          .catch(swallowError)
        writeJson(response, 202, routeState.restart.state())
        return
      }
      if (request.method === "DELETE") {
        writeJson(response, 200, await routeState.restart.cancel())
        return
      }
    }

    if (request.method === "POST" && url.pathname === "/v1/shutdown") {
      writeJson(response, 202, { ok: true })
      config.onShutdownRequested?.()
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/capabilities") {
      writeJson(response, 200, await discoverCapabilities(services, url))
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/auth/connection-token") {
      writeJson(response, 200, {
        token: await run(services.db.getOrCreateConnectionToken),
        createdAt: new Date().toISOString()
      })
      return
    }

    if (request.method === "POST" && url.pathname === "/v1/auth/connection-token/rotate") {
      writeJson(response, 201, {
        token: await run(services.db.rotateConnectionToken),
        createdAt: new Date().toISOString()
      })
      return
    }

    if (request.method === "POST" && url.pathname === "/v1/auth/pairing-token") {
      writeJson(response, 201, {
        token: await run(services.db.issuePairingToken),
        createdAt: new Date().toISOString()
      })
      return
    }

    if (await routeGatewayInvoke(services, request, response, url)) return
    if (await routeProjects(services, config, fanout, request, response, url)) return
    if (await routeClientControl(routeState.clientControl, config, request, response, url)) return
    if (await routeWorkspaces(services, fanout, routeState, config, request, response, url)) {
      return
    }
    if (await routeHarnesses(services, config, fanout, request, response, url)) {
      return
    }
    if (await routeBrowserUse(services, request, response, url)) {
      return
    }
    if (await routeMachineMcps(services, config, fanout, request, response, url)) {
      return
    }
    if (await routeToolIcons(services, request, response, url)) {
      return
    }
    if (await routeMcps(services, request, response, url)) {
      return
    }
    if (await routeMcpScopes(services, request, response, url)) {
      return
    }
    if (await routeNativeMcps(services, request, response, url)) {
      return
    }
    if (await routeSkills(services, request, response, url)) {
      return
    }
    if (await routeSync(services, config, fanout, request, response, url)) {
      return
    }
    if (await routePlugins(services, fanout, request, response, url)) {
      return
    }
    if (await routeSessions(services, fanout, routeState, request, response, url, config)) {
      return
    }
    if (await routeFiles(services, request, response, url)) {
      return
    }
    if (await routeFs(services, request, response, url)) {
      return
    }
    if (await routeCloud(config, request, response, url)) {
      return
    }
    if (routeNetDirect(config, request, response, url)) {
      return
    }
    if (await routeTerminals(services, request, response, url)) {
      return
    }

    throw new HttpFailure(404, "Route not found")
  } catch (cause) {
    writeFailure(response, cause)
  }
}

const serverUpdateChannelFrom = (value: string | null): ServerUpdateChannel =>
  value === "alpha" ? "alpha" : "stable"

const updateInfoSignature = (info: UpdateInfo): string =>
  JSON.stringify([
    info.updateAvailable,
    info.latestVersion,
    info.latestBuildNumber ?? null,
    info.currentVersion,
    info.channel,
    info.lastApply?.state ?? null,
    info.lastApply?.message ?? null,
    info.lastApply?.progress ?? null,
    info.lastApply?.at ?? null
  ])

const withRestartDrain = (routeState: RouteState, info: UpdateInfo): UpdateInfo => {
  const drain = routeState.restart.state()
  if (drain.state === "idle" || info.lastApply?.state === "failed") return info
  if (
    drain.state === "drained" &&
    info.lastApply?.state === "installing" &&
    Date.parse(info.lastApply.at) >= Date.parse(drain.startedAt)
  )
    return info
  const chats = `${drain.remaining} chat${drain.remaining === 1 ? "" : "s"}`
  return {
    ...info,
    lastApply: {
      state: drain.state === "draining" ? "draining" : "installing",
      message:
        drain.state === "draining"
          ? `Waiting for ${chats} to finish`
          : "Restarting to install the update",
      targetVersion: info.latestVersion,
      at: drain.startedAt
    }
  }
}

const publishUpdateChanged = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  info: UpdateInfo
): void => {
  const signature = updateInfoSignature(info)
  if (routeState.updateSignature.value === signature) return
  routeState.updateSignature.value = signature
  void appendAndPublish(services.db, fanout, "update.changed", "server", info).catch(swallowError)
}
import { isBrowserProxyRequest } from "./infra/browser-forward-proxy.js"
