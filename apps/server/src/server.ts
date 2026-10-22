import { createServer } from "node:http"
import type { IncomingMessage, Server, ServerResponse } from "node:http"
import { Socket, type AddressInfo } from "node:net"

import type { SessionUpdateGate } from "@codevisor/api"
import { Effect } from "effect"
import { WebSocketServer } from "ws"

import { archiveJobs } from "./archive-jobs.js"
import type { BootListener } from "./boot-listener.js"
import { makeAttentionSettleScheduler } from "./infra/attention-settle.js"
import { BrowserProxy } from "./infra/browser-proxy.js"
import { ClientControlBroker } from "./infra/client-control.js"
import { hasExistingListener } from "./infra/listener-probe.js"
import { readMcpOverlays } from "./infra/mcp-fleet.js"
import { SHARED_ACCOUNTS_NAMESPACE } from "./infra/shared-account-store.js"
import { adoptLegacySyncIdentity } from "./infra/sync-identity.js"
import { forwardTerminalTitles } from "./infra/terminal-titles.js"
import {
  makeFilePausedTurnStore,
  makeMemoryPausedTurnStore,
  observePausedTurns
} from "./paused-turns.js"
import { makeRestartCoordinator } from "./restart-drain.js"
import { resumeSessionsAfterRestart } from "./restart-resume.js"
import { makeFileRestartSnapshotStore, makeMemoryRestartSnapshotStore } from "./restart-snapshot.js"
import { makeServerAutoResume } from "./routes/auto-resume-dispatch.js"
import { makeBotConversationListener } from "./routes/bot-conversation.js"
import { upgradeAllBotInstructions } from "./routes/bot-instructions.js"
import { handleUpgrade } from "./routes/events.js"
import { backfillProjectRepoUrls } from "./routes/project-repo-identity.js"
import { makeSessionEventRouter } from "./routes/session-event-router.js"
import {
  drainPromptQueue,
  makeTurnDispatchListener,
  reconcileOrphanedSessionTurns,
  reconcileStaleStreamingTurns
} from "./routes/sessions.js"
import { makeAuthSyncRefreshScheduler } from "./routes/sync-readiness.js"
import { runBackgroundSyncReconcile } from "./routes/sync-reconcilers.js"
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
import {
  startSharedAccountSweep,
  startWorkspaceGitMonitorIfEnabled,
  subscribeSessionActivity
} from "./server-monitors.js"
import { handleRequest } from "./server-router.js"
import { continueAfterUpdate, makeUpdateResumer } from "./update-resume.js"
import { makeServerUpdateRun } from "./update-run-server.js"
import { reconcileWorktreeArchives } from "./worktree-reconcile.js"

export * from "./server-context.js"
export { defaultServerConfig } from "./server-config.js"
export { reconcileOrphanedSessionTurns, reconcileStaleStreamingTurns }

export const makeCodevisorServerApp = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  webSocketServer = new WebSocketServer({ noServer: true })
): CodevisorServerApp => {
  const turns = {
    activePromptSessions: new Set<string>(),
    promptTurnReleases: new Map<string, () => void>(),
    activeTurnSessions: new Set<string>(),
    restartHeldSessions: new Map<string, SessionUpdateGate>()
  }
  const restartSnapshot =
    config.restartSnapshotPath === undefined
      ? makeMemoryRestartSnapshotStore()
      : makeFileRestartSnapshotStore(config.restartSnapshotPath)
  const publishRestartDrain = (): void => {
    void appendAndPublish(
      services.db,
      fanout,
      "restart.drain.updated",
      "server",
      restart.state()
    ).catch(swallowError)
    updateRun.noteChatsChanged()
  }
  const pausedTurns = observePausedTurns(
    config.pausedTurnsPath === undefined
      ? makeMemoryPausedTurnStore()
      : makeFilePausedTurnStore(config.pausedTurnsPath),
    publishRestartDrain
  )
  const updateResume = makeUpdateResumer({
    pausedTurns,
    continueSession: (turn) => continueAfterUpdate(services, fanout, routeState, config.id, turn)
  })
  const restart = makeRestartCoordinator({
    services,
    fanout,
    turns,
    snapshot: restartSnapshot,
    pausedTurns,
    redrain: (sessionId) => drainPromptQueue(services, fanout, routeState, config.id, sessionId),
    resumePaused: () => updateResume.resume(pausedTurns.read()),
    onChange: publishRestartDrain
  })
  const updateRun = makeServerUpdateRun({
    services,
    fanout,
    restart,
    pausedTurns,
    updater: config.updater,
    routeState: () => routeState
  })
  const browserProxy = new BrowserProxy()
  const clientControl = new ClientControlBroker()
  const routeState: RouteState = {
    clientControl,
    browserProxy,
    ...turns,
    gatedSessions: new Map(),
    pendingPromptActions: new Set(),
    pendingSessionCreates: new Map(),
    turnHeldSessions: new Set(),
    updateSignature: {},
    restart,
    updateRun,
    updateResume
  }
  updateResume.resume(pausedTurns.read())
  if (pausedTurns.read().length > 0) publishRestartDrain()
  void resumeSessionsAfterRestart(services, fanout, routeState, config.id, restartSnapshot).catch(
    swallowError
  )
  const unsubscribeTurns = fanout.subscribe(
    makeTurnDispatchListener(services, fanout, routeState, config.id)
  )
  const unsubscribeBotConversations = fanout.subscribe(
    makeBotConversationListener(services, fanout)
  )
  const sessionEvents = makeSessionEventRouter(services, fanout, routeState, config.id)
  const unsubscribeSessionEvents = fanout.subscribe(sessionEvents.listener)
  const unsubscribeJobEvents = services.mcp?.jobs.subscribe(sessionEvents.onJobFinished)
  void upgradeAllBotInstructions(services).catch(swallowError)
  /* v8 ignore next 3 */
  const staleTurnSweep = setInterval(() => {
    void reconcileStaleStreamingTurns(services, fanout, routeState, config.id).catch(swallowError)
    void backfillProjectRepoUrls(
      services.db,
      config.id,
      fanout,
      services.resolveGitEnvironment
    ).catch(swallowError)
  }, 60_000)
  staleTurnSweep.unref()
  const attentionSettle = makeAttentionSettleScheduler(services.db, fanout)
  const autoResume = makeServerAutoResume(services, fanout, routeState, config.id)
  routeState.autoResume = autoResume
  const closeTerminalTitles = forwardTerminalTitles(services.db, services.terminal, fanout)
  const workspaceGit = startWorkspaceGitMonitorIfEnabled(services, config, fanout)
  void attentionSettle.recover().catch(swallowError)
  void autoResume.recover().catch(swallowError)
  const activeSessionIds = new Set<string>()
  const unsubscribeSessionActivity = subscribeSessionActivity(config, fanout, activeSessionIds)
  const authSyncRefresh = makeAuthSyncRefreshScheduler(services, config, fanout)
  const unsubscribeSharedAccounts = services.sharedAccounts?.subscribe((entries) => {
    void appendAndPublish(services.db, fanout, "sync.changed", SHARED_ACCOUNTS_NAMESPACE, {
      namespace: SHARED_ACCOUNTS_NAMESPACE,
      entries
    }).catch(swallowError)
    authSyncRefresh.request()
  })
  const unsubscribeNotices = services.sharedAccounts?.subscribeNotices((harnessId, notice) => {
    void appendAndPublish(services.db, fanout, "harness.notice", harnessId, notice).catch(
      swallowError
    )
  })
  let sharedAccountReconcile: Promise<void> | undefined
  const reconcileSharedAccounts = () => {
    sharedAccountReconcile = services.sharedAccounts?.reconcile().catch(swallowError)
  }
  reconcileSharedAccounts()
  const sharedAccountSweep = startSharedAccountSweep(services, reconcileSharedAccounts)
  sharedAccountSweep?.unref()
  /* v8 ignore next 9 */
  const unsubscribeAuth = services.auth?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      () => undefined
    )
    if (event.kind === "harness.account.updated") {
      authSyncRefresh.request()
    }
  })
  /* v8 ignore next */
  const unsubscribeLifecycle = services.lifecycle?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      () => undefined
    )
    authSyncRefresh.request()
  })
  const unsubscribePlugins = services.plugins?.subscribe((event) => {
    void appendAndPublish(services.db, fanout, event.kind, event.subjectId, event.payload).catch(
      swallowError
    )
  })
  const unsubscribeGate = services.lifecycle?.onGateReleased((harnessId) => {
    const catalogName = services.agents.catalog.find(
      (definition) => definition.id === harnessId
    )?.name
    /* v8 ignore next */
    const harnessName = catalogName ?? harnessId
    for (const [sessionId, gatedHarnessId] of Array.from(routeState.gatedSessions)) {
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
      if (result.adoptedOAuth.length > 0) {
        void runBackgroundSyncReconcile(services, config, fanout, "mcps")
      }
    })
    .catch(swallowError)
  const mcpAtBoot = services.mcp
  if (mcpAtBoot !== undefined) {
    void identityAdopted
      .then(() => readMcpOverlays(services.db, config.id))
      .then((overlays) => mcpAtBoot.setLocalSuppression(overlays.disabledHere))
      .catch(swallowError)
  }
  const unsubscribeMcpChanges = services.mcp?.subscribeServersChanged((id) => {
    void appendAndPublish(services.db, fanout, "mcp.updated", id, { id }).catch(swallowError)
  })
  /* v8 ignore next 3 */
  const unsubscribeRotations = services.mcp?.subscribeCredentialsRotated(() => {
    void runBackgroundSyncReconcile(services, config, fanout, "mcps")
  })
  const app = {
    handleRequest: (request: IncomingMessage, response: ServerResponse): void => {
      void handleRequest(services, config, fanout, routeState, request, response)
    },
    handleConnect: (request: IncomingMessage, socket: Socket, head: Buffer) =>
      browserProxy.handleConnect(request, socket, head),
    handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer): void => {
      if (isBrowserProxyRequest(request)) {
        browserProxy.handleUpgrade(request, socket, head)
        return
      }
      void handleUpgrade(
        services,
        config,
        fanout,
        request,
        socket,
        head,
        webSocketServer,
        clientControl
      )
    },
    close: serverCloseAttempt(async () => {
      browserProxy.close()
      clientControl.close()
      clearInterval(staleTurnSweep)
      restart.close()
      updateResume.close()
      attentionSettle.close()
      autoResume.close()
      unsubscribeTurns()
      unsubscribeBotConversations()
      unsubscribeSessionEvents()
      unsubscribeJobEvents?.()
      unsubscribeSessionActivity?.()
      activeSessionIds.clear()
      config.sessionActivity?.stop()
      unsubscribeAuth?.()
      unsubscribeSharedAccounts?.()
      unsubscribeNotices?.()
      clearInterval(sharedAccountSweep)
      services.sharedAccounts?.gateway.close()
      authSyncRefresh.close()
      unsubscribeLifecycle?.()
      unsubscribePlugins?.()
      unsubscribeGate?.()
      unsubscribeRotations?.()
      unsubscribeMcpChanges?.()
      webSocketServer.close()
      services.plugins?.close()
      void services.mcp?.close().catch(swallowError)
      await sharedAccountReconcile
      await closeTerminalTitles()
      await workspaceGit?.close()
      await archiveJobs(services).jobsFinished()
    })
  }
  return app
}

export const startCodevisorServer = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  bootListener?: BootListener
): Effect.Effect<RunningCodevisorServer, ServerError> =>
  Effect.gen(function* () {
    const fanout = yield* makeEventFanout
    yield* Effect.sync(() => sweepAttachmentTempFiles())
    if (
      bootListener === undefined &&
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
    return yield* Effect.tryPromise({
      try: () =>
        new Promise<RunningCodevisorServer>((resolve, reject) => {
          let app: ReturnType<typeof makeCodevisorServerApp> | undefined
          const onRequest = (request: IncomingMessage, response: ServerResponse): void => {
            if (app === undefined) {
              response.writeHead(503, { "Content-Type": "application/json" })
              response.end(JSON.stringify({ error: "Server recovery is still in progress" }))
              return
            }
            app.handleRequest(request, response)
          }
          let server: Server
          if (bootListener === undefined) {
            server = createServer(onRequest)
          } else {
            bootListener.detach()
            server = bootListener.server
            server.on("request", onRequest)
          }
          server.on("connect", (request, socket, head) => {
            if (app === undefined || !(socket instanceof Socket)) {
              socket.destroy()
              return
            }
            app.handleConnect(request, socket, head)
          })
          server.on("upgrade", (request, socket, head) => {
            if (app === undefined || !(socket instanceof Socket)) {
              socket.destroy()
              return
            }
            app.handleUpgrade(request, socket, head)
          })
          const onListening = async (): Promise<void> => {
            server.off("error", reject)
            server.on("error", (error) => {
              console.error(`Server socket error: ${error.message}`)
            })
            const address = server.address()
            /* v8 ignore next */
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
            void backfillProjectRepoUrls(
              services.db,
              config.id,
              fanout,
              services.resolveGitEnvironment
            ).catch(swallowError)
            void reconcileWorktreeArchives(services, fanout, config).catch(swallowError)
            resolve({
              host: config.host,
              port,
              url: `http://${config.host}:${port}`,
              close: closeServer(server, app)
            })
          }
          const listening = (): void => {
            onListening().catch((cause: unknown) => {
              server.close()
              reject(cause)
            })
          }
          server.once("error", reject)
          if (bootListener === undefined) {
            server.listen(config.port, config.host, listening)
          } else {
            listening()
          }
        }),
      /* v8 ignore next */
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
        void Effect.runPromise(app.close)
          .catch(swallowError)
          .finally(() =>
            server.close((error) => {
              /* v8 ignore next */
              if (error !== undefined) return reject(error)
              resolve()
            })
          )
      }),
    /* v8 ignore next */
    catch: (cause) =>
      new ServerError({
        operation: "close",
        message: failureMessage(cause)
      })
  })

const serverCloseAttempt = (runClose: () => Promise<void>): Effect.Effect<void, ServerError> =>
  Effect.tryPromise({
    try: runClose,
    /* v8 ignore next */
    catch: (cause) => new ServerError({ operation: "closeApp", message: failureMessage(cause) })
  })

export { defaultDatabasePath } from "./infra/data-dir.js"
import { isBrowserProxyRequest } from "./infra/browser-forward-proxy.js"
