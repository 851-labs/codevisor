import { makeOpenApiDocument } from "@codevisor/api"
import type { UpdateInfo } from "@codevisor/api"
import type { IncomingMessage, ServerResponse } from "node:http"
import { hostname } from "node:os"
import { readTailnetPeers } from "./infra/tailnet.js"
import type { ServerUpdateChannel } from "@codevisor/updater"
import {
  appendAndPublish,
  authorize,
  HttpFailure,
  parseRequestUrl,
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
import { routeBrowserUse } from "./routes/browser-use.js"
import { routeCloud } from "./routes/cloud.js"
import { routeNetDirect } from "./routes/net-direct.js"
import { handleEvents } from "./routes/events.js"
import { routeFiles } from "./routes/files.js"
import { routeFs } from "./routes/fs.js"
import { discoverCapabilities, routeHarnesses } from "./routes/harnesses.js"
import { routeMcps, routeMcpScopes, routeNativeMcps } from "./routes/mcps.js"
import { routeProjects } from "./routes/projects.js"
import { routeSessions } from "./routes/sessions.js"
import { routePluginProxy, routePlugins } from "./routes/plugins.js"
import { routeSkills } from "./routes/skills.js"
import { configMutationNamespace, runBackgroundSyncReconcile } from "./routes/sync-reconcilers.js"
import { routeSync } from "./routes/sync.js"
import { routeTerminals } from "./routes/terminals.js"
import { routeWorkspaces } from "./routes/workspaces.js"

/// The top-level HTTP request router: server-scoped endpoints inline, then
/// each resource's route module in turn.

export const handleRequest = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  try {
    const url = parseRequestUrl(request)
    // Config mutations propagate instantly: after a successful response
    // goes out, the matching sync plane reconciles in the background so
    // the change enters the replica and publishes sync.changed within a
    // second instead of waiting for a client's periodic sweep.
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

    // Tokenless on purpose: clients probe network peers (e.g. tailnet members)
    // with this manifest to discover Codevisor servers before pairing. Keep the
    // payload minimal — nothing here may reveal projects, sessions, or tokens.
    if (request.method === "GET" && url.pathname === "/v1/discovery") {
      writeJson(response, 200, {
        serverId: config.id,
        machineId: await run(services.db.getOrCreateInstanceId),
        name: config.name,
        kind: config.kind,
        version: config.version,
        platform: process.platform,
        hostname: hostname()
      })
      return
    }

    // The gateway carries its own short-lived per-session bearer credential;
    // do not run it through the machine-pairing token verifier.
    if (url.pathname === "/mcp/gateway") {
      if (services.mcp === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
      await services.mcp.handleGatewayRequest(request, response)
      return
    }

    // Pane webviews cannot attach the machine bearer token to subresource
    // loads (and the relay strips Authorization), so plugin pane traffic
    // authenticates with per-pane tokens/cookies inside the proxy itself.
    if (url.pathname.startsWith("/v1/plugins/")) {
      if (await routePluginProxy(services, request, response, url)) {
        return
      }
    }

    // OAuth providers redirect a browser without the Codevisor API token. The
    // high-entropy, single-installation state value is validated by the manager.
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

    if (request.method === "GET" && url.pathname === "/v1/events") {
      await authorize(services.db, config, request)
      await handleEvents(services.db, fanout, url, response)
      return
    }

    await authorize(services.db, config, request)

    if (request.method === "GET" && url.pathname === "/v1/events/cursor") {
      writeJson(response, 200, { cursor: await run(services.db.latestEventCursor) })
      return
    }

    // The machine's view of its tailnet, for clients that can't enumerate
    // peers themselves (iOS). Authenticated: the peer list names every device
    // on the user's tailnet, which is far more than /v1/discovery reveals.
    if (request.method === "GET" && url.pathname === "/v1/tailnet/peers") {
      const peers = await readTailnetPeers()
      writeJson(
        response,
        200,
        peers === undefined ? { available: false, peers: [] } : { available: true, peers }
      )
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/info") {
      // Live registrations (app-driven connect/disconnect) win over the
      // boot-time snapshot so clients never match against a stale device id.
      const cloudDeviceId =
        config.cloud === undefined ? config.cloudDeviceId : config.cloud.deviceId()
      writeJson(response, 200, {
        id: config.id,
        name: config.name,
        kind: config.kind,
        version: config.version,
        platform: process.platform,
        bindHost: config.host,
        features: [
          "canonical-chat-v1",
          "session-event-stream-v1",
          "transcript-pagination-v1",
          ...(services.plugins === undefined ? [] : ["plugins-v1"])
        ],
        machineId: await run(services.db.getOrCreateInstanceId),
        arch: process.arch,
        hostname: hostname(),
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
        // `refresh=1` bypasses the updater's check cache: clients force it
        // when the user is looking at a machine so the banner reflects a
        // release cut minutes ago, not the last background probe.
        // `channel=alpha` opts this check into pre-releases (the client
        // forwards its own alpha-updates preference); anything else is
        // stable.
        const force = url.searchParams.get("refresh") === "1"
        const channel = serverUpdateChannelFrom(url.searchParams.get("channel"))
        const info = await config.updater.check({ channel, force })
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
      // Refuse to restart while chats are mid-turn — applying the update would
      // kill the in-flight work. Clients disable their update button too, but
      // another client on this server could still ask.
      if (routeState.activePromptSessions.size > 0) {
        writeJson(response, 200, { accepted: false, reason: "busy" })
        return
      }
      // Forced: the decision to restart the server must rest on the live
      // release state, never a stale cache entry.
      const channel = serverUpdateChannelFrom(url.searchParams.get("channel"))
      const info = await config.updater.check({ channel, force: true })
      publishUpdateChanged(services, fanout, routeState, info)
      if (!info.updateAvailable) {
        writeJson(response, 200, { accepted: false, targetVersion: info.currentVersion })
        return
      }
      // Acknowledge first: applying restarts the process, so this response
      // must be on the wire before the server goes away. The build number is
      // the reliable "did it land" marker for clients: version strings
      // diverge between the alpha manifest (full prerelease tag) and the
      // installed runtime (base marketing version), build numbers never do.
      writeJson(response, 202, {
        accepted: true,
        targetVersion: info.latestVersion,
        ...(info.latestBuildNumber === undefined
          ? {}
          : { targetBuildNumber: info.latestBuildNumber })
      })
      config.updater.apply({ channel }).catch(() => undefined)
      return
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

    if (await routeProjects(services, config, fanout, request, response, url)) {
      return
    }
    if (await routeWorkspaces(services, fanout, routeState, config, request, response, url)) {
      return
    }
    if (await routeHarnesses(services, request, response, url)) {
      return
    }
    if (await routeBrowserUse(services, request, response, url)) {
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

/// Lenient channel parsing: only an explicit `alpha` opts into
/// pre-releases; absent, empty, or unknown values stay on stable.
const serverUpdateChannelFrom = (value: string | null): ServerUpdateChannel =>
  value === "alpha" ? "alpha" : "stable"

/// One release-state fingerprint per published update.changed: repeated
/// checks with an unchanged outcome stay silent, while a new release, a
/// converged install, or a fresh unattended-apply report each publish once.
/// `checkedAt` is deliberately excluded — it changes on every check.
const updateInfoSignature = (info: UpdateInfo): string =>
  JSON.stringify([
    info.updateAvailable,
    info.latestVersion,
    info.latestBuildNumber ?? null,
    info.currentVersion,
    info.channel,
    info.lastApply?.state ?? null,
    info.lastApply?.at ?? null
  ])

/// Emits update.changed when a check's outcome differs from the last one
/// published. Every client already force-checks reachable machines on its
/// own cadence, so any one client's probe keeps every other connected
/// client's fleet state fresh — no server-side timer needed.
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
