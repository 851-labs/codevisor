import { createServer } from "node:http"
import type { IncomingMessage, Server, ServerResponse } from "node:http"
import { connect } from "node:net"
import type { AddressInfo, Socket } from "node:net"
import { Effect } from "effect"
import { WebSocketServer } from "ws"
import {
  appendAndPublish,
  failureMessage,
  makeEventFanout,
  ServerError,
  swallowError,
  sweepAttachmentTempFiles
} from "./server-context.js"
import type {
  CodevisorServerApp,
  CodevisorServerConfig,
  CodevisorServerServices,
  EventFanout,
  RouteState,
  RunningCodevisorServer
} from "./server-context.js"
import { makeAttentionSettleScheduler } from "./infra/attention-settle.js"
import { handleUpgrade } from "./routes/events.js"
import { backfillProjectRepoUrls } from "./routes/project-repo-identity.js"
import { readMcpOverlays } from "./infra/mcp-fleet.js"
import { adoptLegacySyncIdentity } from "./infra/sync-identity.js"
import {
  drainPromptQueue,
  makeTurnDispatchListener,
  reconcileOrphanedSessionTurns,
  reconcileStaleStreamingTurns
} from "./routes/sessions.js"
import {
  makeAuthSyncRefreshScheduler,
  runBackgroundSyncReconcile
} from "./routes/sync-reconcilers.js"
import { handleRequest } from "./server-router.js"
import {
  makeFileRestartSnapshotStore,
  makeMemoryRestartSnapshotStore,
  makeRestartCoordinator
} from "./restart-drain.js"
import { resumeSessionsAfterRestart } from "./restart-resume.js"

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
  directPathEnabled: overrides.directPathEnabled ?? true,
  worktreeNameStyle: overrides.worktreeNameStyle ?? "production",
  auth: overrides.auth ?? {
    allowLocalhostWithoutAuth: true,
    requireBearerToken: false
  },
  onShutdownRequested: overrides.onShutdownRequested,
  updater: overrides.updater,
  restartSnapshotPath: overrides.restartSnapshotPath,
  restartDrainTimeoutMs: overrides.restartDrainTimeoutMs,
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
  // The restart drain and the route state reference each other: the drain
  // reads the live-turn sets and prompt dispatch reads the drain's gate.
  const turns = {
    activePromptSessions: new Set<string>(),
    activeTurnSessions: new Set<string>(),
    restartHeldSessions: new Set<string>()
  }
  const restartSnapshot =
    config.restartSnapshotPath === undefined
      ? makeMemoryRestartSnapshotStore()
      : makeFileRestartSnapshotStore(config.restartSnapshotPath)
  const restart = makeRestartCoordinator({
    services,
    fanout,
    turns,
    snapshot: restartSnapshot,
    defaultTimeoutMs: config.restartDrainTimeoutMs,
    // Resolved at call time: routeState is assembled just below.
    redrain: (sessionId) => drainPromptQueue(services, fanout, routeState, config.id, sessionId)
  })
  const routeState: RouteState = {
    ...turns,
    gatedSessions: new Map(),
    pendingPromptActions: new Set(),
    pendingSessionCreates: new Map(),
    turnHeldSessions: new Set(),
    updateSignature: {},
    restart
  }
  // The previous process drained for a restart: bring its live sessions
  // back and dispatch the prompts it held. Fire-and-forget so the listener
  // is answering /health while agents reconnect.
  void resumeSessionsAfterRestart(services, fanout, routeState, config.id, restartSnapshot).catch(
    swallowError
  )
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
  const authSyncRefresh = makeAuthSyncRefreshScheduler(services, config, fanout)
  /* v8 ignore next 9 -- the auth manager invokes this thin event-forwarding callback. */
  const unsubscribeAuth = services.auth?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      () => undefined
    )
    // Auth drift is fleet-visible (Phase 19): an account flipping state —
    // a session dying of auth, a login completing — republishes this
    // machine's roster immediately instead of waiting for a client sweep.
    if (event.kind === "harness.account.updated") {
      authSyncRefresh.request()
    }
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
  // Identity first: a fleet that predates stable app-hosted ids still
  // carries this machine's overlays (and OAuth refresh ownership) under
  // "local", and they must be ours before suppression is derived from them.
  const identityAdopted = adoptLegacySyncIdentity({
    db: services.db,
    serverId: config.id,
    kind: config.kind,
    mcp: services.mcp
  })
    .then((result) => {
      for (const change of result.changed) {
        void appendAndPublish(services.db, fanout, "sync.changed", change.namespace, {
          namespace: change.namespace,
          entries: change.entries
        }).catch(swallowError)
      }
      // Re-owned tokens republish so mirrors learn who rotates them now.
      if (result.adoptedOAuth.length > 0) {
        void runBackgroundSyncReconcile(services, config, fanout, "mcps")
      }
    })
    .catch(swallowError)
  // Suppression is enforcement state, not cache: the per-machine disable
  // overlays live in the sync replica, so a restarted server must re-apply
  // them before any session asks for tools. Enforcement only — the durable
  // readiness entry republishes on its usual triggers, not at boot.
  const mcpAtBoot = services.mcp
  if (mcpAtBoot !== undefined) {
    void identityAdopted
      .then(() => readMcpOverlays(services.db, config.id))
      .then((overlays) => mcpAtBoot.setLocalSuppression(overlays.disabledHere))
      .catch(swallowError)
  }
  // Every visible change to a managed MCP record (a connection settling,
  // an OAuth expiry, a synced enable flip) reaches clients as mcp.updated
  // so settings views follow the machine live instead of polling.
  const unsubscribeMcpChanges = services.mcp?.subscribeServersChanged((id) => {
    void appendAndPublish(services.db, fanout, "mcp.updated", id, { id }).catch(swallowError)
  })
  // A rotated OAuth token republishes immediately: the refresh owner's
  // config plane must carry the new material before any mirror's old
  // access token expires.
  /* v8 ignore next 3 -- rotation events fire from the live OAuth refresh timer. */
  const unsubscribeRotations = services.mcp?.subscribeCredentialsRotated(() => {
    void runBackgroundSyncReconcile(services, config, fanout, "mcps")
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
      restart.close()
      attentionSettle.close()
      unsubscribeTurns()
      unsubscribeSessionActivity?.()
      activeSessionIds.clear()
      config.sessionActivity?.stop()
      unsubscribeAuth?.()
      authSyncRefresh.close()
      unsubscribeLifecycle?.()
      unsubscribePlugins?.()
      unsubscribeGate?.()
      unsubscribeRotations?.()
      unsubscribeMcpChanges?.()
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
            // Projects recorded before remotes were tracked learn theirs
            // now, off the request path; the list route repeats the same
            // reconcile (memoized) for anything this sweep misses.
            void backfillProjectRepoUrls(
              services.db,
              config.id,
              fanout,
              services.resolveGitEnvironment
            ).catch(swallowError)
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
