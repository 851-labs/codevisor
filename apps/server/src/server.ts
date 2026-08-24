import { makeOpenApiDocument, type UpdateInfo } from "@codevisor/api"
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http"
import { hostname } from "node:os"
import { connect, type AddressInfo, type Socket } from "node:net"
import { Effect } from "effect"
import { WebSocketServer } from "ws"
import { readTailnetPeers } from "./infra/tailnet.js"
import type { ServerUpdateChannel } from "@codevisor/updater"
import {
  appendAndPublish,
  authorize,
  failureMessage,
  HttpFailure,
  makeEventFanout,
  parseRequestUrl,
  run,
  ServerError,
  swallowError,
  sweepAttachmentTempFiles,
  writeFailure,
  writeJson,
  type CodevisorServerApp,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState,
  type RunningCodevisorServer
} from "./server-context.js"
import { makeAttentionSettleScheduler } from "./infra/attention-settle.js"
import { routeBrowserUse } from "./routes/browser-use.js"
import { routeCloud } from "./routes/cloud.js"
import { routeNetDirect } from "./routes/net-direct.js"
import { handleEvents, handleUpgrade } from "./routes/events.js"
import { routeFiles } from "./routes/files.js"
import { routeFs } from "./routes/fs.js"
import { discoverCapabilities, routeHarnesses } from "./routes/harnesses.js"
import { routeMcps, routeMcpScopes, routeNativeMcps } from "./routes/mcps.js"
import { routeProjects } from "./routes/projects.js"
import {
  drainPromptQueue,
  makeTurnDispatchListener,
  reconcileOrphanedSessionTurns,
  reconcileStaleStreamingTurns,
  routeSessions
} from "./routes/sessions.js"
import { routePluginProxy, routePlugins } from "./routes/plugins.js"
import { routeSkills } from "./routes/skills.js"
import { routeTerminals } from "./routes/terminals.js"
import { routeWorkspaces } from "./routes/workspaces.js"

export * from "./server-context.js"
export { reconcileOrphanedSessionTurns, reconcileStaleStreamingTurns }

export const defaultServerConfig = (
  overrides: Partial<CodevisorServerConfig> = {}
): CodevisorServerConfig => ({
  id: overrides.id ?? "local",
  name: overrides.name ?? "Local Codevisor",
  version: overrides.version ?? "0.1.0",
  bootId: overrides.bootId ?? "test-boot",
  processId: overrides.processId ?? process.pid,
  appOwned: overrides.appOwned ?? false,
  buildNumber: overrides.buildNumber,
  sourceRevision: overrides.sourceRevision,
  serviceManaged: overrides.serviceManaged ?? false,
  kind: overrides.kind ?? "local",
  host: overrides.host ?? "127.0.0.1",
  port: overrides.port ?? 49361,
  worktreeNameStyle: overrides.worktreeNameStyle ?? "production",
  auth: overrides.auth ?? {
    allowLocalhostWithoutAuth: true,
    requireBearerToken: false
  },
  onShutdownRequested: overrides.onShutdownRequested,
  updater: overrides.updater,
  sessionActivity: overrides.sessionActivity,
  cloudDeviceId: overrides.cloudDeviceId,
  cloud: overrides.cloud
})

export const makeCodevisorServerApp = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  webSocketServer = new WebSocketServer({ noServer: true })
): CodevisorServerApp => {
  const routeState: RouteState = {
    activePromptSessions: new Set(),
    activeTurnSessions: new Set(),
    gatedSessions: new Map(),
    pendingPromptActions: new Set(),
    pendingSessionCreates: new Map(),
    turnHeldSessions: new Set(),
    updateSignature: {}
  }
  // Turn lifecycle → prompt dispatch: a harness can start a turn on its own
  // (task-notification follow-up after a background task finishes), which no
  // prompt drain owns. Track live turns from the event stream so
  // drainPromptQueue can hold, and re-drain held sessions the moment the
  // turn settles. Synthetic terminal events (stale-turn reconciliation) flow
  // through the same fanout, so a crashed harness can never wedge the hold.
  const unsubscribeTurns = fanout.subscribe(
    makeTurnDispatchListener(services, fanout, routeState, config.id)
  )
  // Startup reconciliation only heals rows stranded by a dead process. Rows
  // stranded while this process keeps running (harness crash, lost terminal
  // event) would otherwise render as an endless in-progress turn to every
  // client until the next restart — sweep for them periodically.
  /* v8 ignore next 3 -- timer-driven: the sweep itself is tested directly. */
  const staleTurnSweep = setInterval(() => {
    void reconcileStaleStreamingTurns(services, fanout, routeState, config.id).catch(swallowError)
  }, 60_000)
  staleTurnSweep.unref()
  // Deferred attention settling: a turn that ended while a subagent was
  // still running parks its unread bump; this scheduler fires it once the
  // grace deadline passes without the agent being re-invoked. Recovery also
  // drains parked finishes stranded by a previous process (startup
  // reconciliation has already cleared their stale task snapshots).
  const attentionSettle = makeAttentionSettleScheduler(services.db, fanout)
  void attentionSettle.recover().catch(swallowError)
  const activeSessionIds = new Set<string>()
  const unsubscribeSessionActivity = config.sessionActivity
    ? fanout.subscribe((event) => {
        if (event.kind !== "session.attention.updated") return
        const payload = event.payload
        if (
          typeof payload !== "object" ||
          payload === null ||
          !("sidebarState" in payload) ||
          typeof payload.sidebarState !== "string"
        ) {
          return
        }
        const active = payload.sidebarState === "inProgress"
        if (active) {
          if (activeSessionIds.has(event.subjectId)) return
          activeSessionIds.add(event.subjectId)
        } else {
          if (!activeSessionIds.delete(event.subjectId)) return
        }
        config.sessionActivity?.update(event.subjectId, active)
      })
    : undefined
  /* v8 ignore next -- the auth manager invokes this thin event-forwarding callback. */
  const unsubscribeAuth = services.auth?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      () => undefined
    )
  })
  /* v8 ignore next -- the lifecycle manager invokes this thin event-forwarding callback. */
  const unsubscribeLifecycle = services.lifecycle?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      () => undefined
    )
  })
  // Plugin runtime transitions ride the same fanout so Settings chips and
  // pane error cards update live on every client.
  const unsubscribePlugins = services.plugins?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      swallowError
    )
  })
  // Gate release → tell every held session and re-drain its durable queue.
  const unsubscribeGate = services.lifecycle?.onGateReleased((harnessId) => {
    const catalogName = services.agents.catalog.find(
      (definition) => definition.id === harnessId
    )?.name
    /* v8 ignore next -- defensive: releases for uncataloged harnesses fall back to the id. */
    const harnessName = catalogName ?? harnessId
    for (const [sessionId, gatedHarnessId] of [...routeState.gatedSessions]) {
      if (gatedHarnessId !== harnessId) continue
      routeState.gatedSessions.delete(sessionId)
      void appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
        harnessId,
        harnessName,
        state: "released"
      }).catch(swallowError)
      void drainPromptQueue(services, fanout, routeState, config.id, sessionId).catch(swallowError)
    }
  })
  const app = {
    handleRequest: (request: IncomingMessage, response: ServerResponse): void => {
      void handleRequest(services, config, fanout, routeState, request, response)
    },
    handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer): void => {
      void handleUpgrade(services, config, fanout, request, socket, head, webSocketServer)
    },
    close: serverAttempt("closeApp", () => {
      clearInterval(staleTurnSweep)
      attentionSettle.close()
      unsubscribeTurns()
      unsubscribeSessionActivity?.()
      activeSessionIds.clear()
      config.sessionActivity?.stop()
      unsubscribeAuth?.()
      unsubscribeLifecycle?.()
      unsubscribePlugins?.()
      unsubscribeGate?.()
      webSocketServer.close()
      services.plugins?.close()
      void services.mcp?.close().catch(swallowError)
    })
  }
  return app
}

/// True when something already accepts connections on the address this server
/// is about to claim. Bind errors alone cannot detect this: the kernel happily
/// grants 127.0.0.1:PORT while another process holds *:PORT, and the more
/// specific bind then silently captures all loopback traffic.
const hasExistingListener = (host: string, port: number): Promise<boolean> =>
  new Promise((resolve) => {
    const probeHost = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host
    const socket = connect({ host: probeHost, port })
    const done = (listening: boolean): void => {
      socket.destroy()
      resolve(listening)
    }
    socket.once("connect", () => done(true))
    socket.once("error", () => done(false))
    /* v8 ignore next -- an OS-level connect timeout is nondeterministic; connect/error cover the observable outcomes. */
    socket.setTimeout(1_000, () => done(false))
  })

export const startCodevisorServer = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig
): Effect.Effect<RunningCodevisorServer, ServerError> =>
  Effect.gen(function* () {
    const fanout = yield* makeEventFanout
    yield* Effect.sync(() => sweepAttachmentTempFiles())
    // An accidental second `serve` against the same data directory once
    // shadow-bound the loopback address of a live server and hijacked its
    // clients mid-turn. Refuse to start when the port is already served;
    // ephemeral ports (tests) cannot conflict and skip the probe.
    if (
      config.port !== 0 &&
      (yield* Effect.promise(() => hasExistingListener(config.host, config.port)))
    ) {
      return yield* Effect.fail(
        new ServerError({
          operation: "start",
          message: `${config.host}:${config.port} already has a listener (another Codevisor server?). Stop the other process or pass a different --port.`
        })
      )
    }
    // Every runtime continuation belongs to this server process. If the
    // previous process died mid-turn, close only the orphaned durable state
    // before accepting clients. Agent processes are deliberately restored on
    // demand by /connect: cold-starting one here for every interrupted chat
    // used to keep /health unavailable for minutes after an app relaunch.
    // This makes startup reconciliation idempotent and prevents a reconnecting
    // UI from inheriting a generating row that can never emit again.
    return yield* Effect.tryPromise({
      try: () =>
        new Promise<RunningCodevisorServer>((resolve, reject) => {
          let app: ReturnType<typeof makeCodevisorServerApp> | undefined
          const server = createServer((request, response) => {
            if (app === undefined) {
              response.writeHead(503, { "Content-Type": "application/json" })
              response.end(JSON.stringify({ error: "Server recovery is still in progress" }))
              return
            }
            app.handleRequest(request, response)
          })
          server.on("upgrade", (request, socket, head) => {
            if (app === undefined) {
              socket.destroy()
              return
            }
            app.handleUpgrade(request, socket as Socket, head)
          })
          server.once("error", reject)
          server.listen(config.port, config.host, async () => {
            server.off("error", reject)
            const address = server.address()
            /* v8 ignore next -- TCP listen always returns AddressInfo here. */
            const port = isAddressInfo(address) ? address.port : config.port
            services.mcp?.setBaseUrl(`http://${config.host}:${port}`)
            try {
              await reconcileOrphanedSessionTurns(services, fanout, config.id)
            } catch (cause) {
              server.close()
              reject(
                new ServerError({
                  operation: "reconcileOrphanedSessions",
                  message: failureMessage(cause)
                })
              )
              return
            }
            app = makeCodevisorServerApp(services, config, fanout)
            resolve({
              host: config.host,
              port,
              url: `http://${config.host}:${port}`,
              close: closeServer(server, app)
            })
          })
        }),
      /* v8 ignore next -- startup errors are surfaced by Node before a server is returned. */
      catch: (cause) =>
        new ServerError({
          operation: "start",
          message: cause instanceof Error ? cause.message : String(cause)
        })
    })
  })

const handleRequest = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  try {
    const url = parseRequestUrl(request)
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

const isAddressInfo = (address: string | AddressInfo | null): address is AddressInfo =>
  typeof address === "object" && address !== null && "port" in address

const closeServer = (server: Server, app: CodevisorServerApp): Effect.Effect<void, ServerError> =>
  Effect.tryPromise({
    try: () =>
      new Promise<void>((resolve, reject) => {
        void Effect.runPromise(app.close).catch(swallowError)
        /* v8 ignore next -- normal test shutdown closes cleanly. */
        server.close((error) => (error === undefined ? resolve() : reject(error)))
      }),
    /* v8 ignore next -- normal test shutdown closes cleanly. */
    catch: (cause) =>
      new ServerError({
        operation: "close",
        message: failureMessage(cause)
      })
  })

const serverAttempt = <A>(operation: string, runSync: () => A): Effect.Effect<A, ServerError> =>
  Effect.try({
    try: runSync,
    /* v8 ignore next -- app close only wraps defensive WebSocket close failures. */
    catch: (cause) =>
      new ServerError({
        operation,
        message: failureMessage(cause)
      })
  })

export { defaultDatabasePath } from "./infra/data-dir.js"
