import type {
  AgentSessionMetadata,
  AgentRuntimeService,
  PromptAttachmentInput,
  RuntimeEvent,
  RuntimeEventSink
} from "@codevisor/agent-runtime"
import { createHash, randomUUID } from "node:crypto"
import type {
  AttachmentRef,
  CreateSessionRequest,
  FileMetadata,
  UpdateSessionRequest,
  EventEnvelope,
  Harness,
  HarnessCapability,
  HarnessUsageLimits,
  Project,
  ProjectLocation,
  PromptAcceptedResponse,
  PromptQueueItem,
  ServerKind,
  SessionConfigOption,
  SessionSummary,
  TerminalClientFrame,
  UpdateInfo,
  Worktree,
  WorktreeSetupUpdate,
  FsListResponse,
  ProjectSetupUpdate
} from "@codevisor/api"
import {
  CreateProjectFromGitRequest as CreateProjectFromGitRequestSchema,
  CreateProjectRequest as CreateProjectRequestSchema,
  CreateMcpServerRequest as CreateMcpServerRequestSchema,
  CreateSkillRequest as CreateSkillRequestSchema,
  DetectMcpAuthRequest as DetectMcpAuthRequestSchema,
  DiscoverRemoteSkillsRequest as DiscoverRemoteSkillsRequestSchema,
  ImportNativeMcpsRequest as ImportNativeMcpsRequestSchema,
  ImportRemoteSkillRequest as ImportRemoteSkillRequestSchema,
  ImportSkillRequest as ImportSkillRequestSchema,
  RemoveNativeMcpRequest as RemoveNativeMcpRequestSchema,
  SetNativeMcpEnabledRequest as SetNativeMcpEnabledRequestSchema,
  SyncSkillsRequest as SyncSkillsRequestSchema,
  MakeSkillGlobalRequest as MakeSkillGlobalRequestSchema,
  SetSkillInstalledRequest as SetSkillInstalledRequestSchema,
  CreateHarnessAccountRequest as CreateHarnessAccountRequestSchema,
  CreateSessionRequest as CreateSessionRequestSchema,
  CreateWorktreeRequest as CreateWorktreeRequestSchema,
  OpenSessionRequest as OpenSessionRequestSchema,
  CancelRequest,
  PromptRequest,
  AnswerPiAuthRequest as AnswerPiAuthRequestSchema,
  AnswerOpenCodeAuthRequest as AnswerOpenCodeAuthRequestSchema,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  TerminalClientFrame as TerminalClientFrameSchema,
  TerminalCreateRequest,
  StartHarnessLoginRequest as StartHarnessLoginRequestSchema,
  StartPiAuthRequest as StartPiAuthRequestSchema,
  StartOpenCodeAuthRequest as StartOpenCodeAuthRequestSchema,
  UpdateHarnessAccountRequest as UpdateHarnessAccountRequestSchema,
  UpdateQueuedPromptRequest,
  UpdateHarnessRequest as UpdateHarnessRequestSchema,
  UpdateMcpServerRequest as UpdateMcpServerRequestSchema,
  UpdateBrowserUseConfigurationRequest as UpdateBrowserUseConfigurationRequestSchema,
  UpdateProjectRequest as UpdateProjectRequestSchema,
  UpdateSessionRequest as UpdateSessionRequestSchema,
  UpsertWorkspaceNotesRequest as UpsertWorkspaceNotesRequestSchema,
  UpsertWorkspaceRequest as UpsertWorkspaceRequestSchema,
  decode,
  makeOpenApiDocument
} from "@codevisor/api"
import {
  AttachmentStoreError,
  DatabaseError,
  managedRepoPath,
  type AttachmentStore,
  type CodevisorDatabaseService
} from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http"
import { existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs"
import { readdir } from "node:fs/promises"
import { homedir, hostname, tmpdir } from "node:os"
import { dirname, join, resolve as resolvePath } from "node:path"
import {
  CloneError,
  GitError,
  addWorktree,
  cloneRepository,
  gitBranchDiffTotals,
  isGitWorkTree,
  isWorktreeBranchCollision,
  listCodevisorWorktreeBranchNames,
  removeWorktree,
  worktreeStartPoint
} from "./git.js"
import { connect, type AddressInfo, type Socket } from "node:net"
import { Context, Effect, Layer, PubSub, Schema } from "effect"
import { WebSocket, WebSocketServer } from "ws"
import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import type { HarnessAuthManager } from "./harness-auth.js"
import type { HarnessLifecycleManager } from "./harness-lifecycle.js"
import { parseCustomHarnessDocument, type CustomHarnessStore } from "./custom-harnesses.js"
import type { McpManager } from "./mcp-manager.js"
import { NativeMcpError, type NativeMcpManager } from "./native-mcp-manager.js"
import { SkillsError, type SkillsManager } from "./skills-manager.js"
import { availableDevelopmentWorktreeName } from "./food-worktree-names.js"
import { availableProductionWorktreeName } from "./worktree-names.js"

export class ServerError extends Schema.TaggedErrorClass<ServerError>()("ServerError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface CodevisorServerAuthConfig {
  readonly requireBearerToken: boolean
  readonly allowLocalhostWithoutAuth: boolean
}

/// Lets the host process implement self-updating: `check` refreshes and
/// returns the update state, `apply` installs the newer release and restarts
/// the server process. Wired up in main.ts; absent in tests and embedded runs.
export interface CodevisorServerUpdater {
  readonly check: () => Promise<UpdateInfo>
  readonly apply: () => Promise<void>
}

export interface CodevisorServerConfig {
  readonly id: string
  readonly name: string
  readonly version: string
  readonly kind: ServerKind
  readonly host: string
  readonly port: number
  readonly worktreeNameStyle: "production" | "development"
  readonly auth: CodevisorServerAuthConfig
  /// Origins allowed to call the HTTP API from a browser context (e.g. the
  /// Tauri desktop webview's tauri://localhost). Never a wildcard: loopback
  /// requests skip token auth, so a wildcard would let any website drive the
  /// server. Empty/absent disables CORS entirely (same-origin only).
  readonly corsOrigins?: ReadonlyArray<string> | undefined
  /// Invoked after `POST /v1/shutdown` is acknowledged so the host process can
  /// exit (used by the macOS app to swap in an updated server runtime).
  readonly onShutdownRequested?: (() => void) | undefined
  readonly updater?: CodevisorServerUpdater | undefined
}

export interface CodevisorServerServices {
  readonly db: CodevisorDatabaseService
  readonly attachments: AttachmentStore
  readonly agents: AgentRuntimeService
  readonly terminal: TerminalManagerService
  readonly auth?: HarnessAuthManager
  readonly mcp?: McpManager
  /// User-defined custom ACP harness persistence + handshake probe. Absent on
  /// hosts that don't support it (embedded runtimes, tests) — routes 501.
  readonly customHarnesses?: CustomHarnessStore
  /// Harness install/update lifecycle (update detection, later install/
  /// update execution). Absent on hosts that don't support it.
  readonly lifecycle?: HarnessLifecycleManager
  /// Discovery over MCP servers registered directly in harness config files.
  /// Absent on hosts that don't support it — routes 501.
  readonly nativeMcp?: NativeMcpManager
  /// Skills discovery over the canonical store and harness skills dirs.
  /// Absent on hosts that don't support it — routes 501.
  readonly skills?: SkillsManager
}

export interface RunningCodevisorServer {
  readonly url: string
  readonly host: string
  readonly port: number
  readonly close: Effect.Effect<void, ServerError>
}

export interface CodevisorServerApp {
  readonly handleRequest: (request: IncomingMessage, response: ServerResponse) => void
  readonly handleUpgrade: (request: IncomingMessage, socket: Socket, head: Buffer) => void
  readonly close: Effect.Effect<void, ServerError>
}

interface RouteState {
  readonly pendingSessionCreates: Map<string, Promise<SessionSummary>>
  readonly pendingPromptActions: Set<string>
  readonly activePromptSessions: Set<string>
  /// Sessions whose prompt dispatch is held by a harness update gate, keyed
  /// to the harness they wait on. Cleared (and re-drained) on gate release.
  readonly gatedSessions: Map<string, string>
}

export class CodevisorServer extends Context.Service<CodevisorServer, CodevisorServerServices>()(
  "@codevisor/server/CodevisorServer"
) {
  static readonly layer = (services: CodevisorServerServices): Layer.Layer<CodevisorServer> =>
    Layer.succeed(CodevisorServer, CodevisorServer.of(services))
}

export class EventFanout {
  readonly sinks = new Set<(event: EventEnvelope) => void>()

  constructor(readonly pubsub: PubSub.PubSub<EventEnvelope>) {}

  publish(event: EventEnvelope): Effect.Effect<void> {
    const pubsub = this.pubsub
    const sinks = this.sinks
    return Effect.gen(function* () {
      yield* PubSub.publish(pubsub, event)
      yield* Effect.sync(() => {
        for (const sink of sinks) {
          sink(event)
        }
      })
    })
  }

  subscribe(sink: (event: EventEnvelope) => void): () => void {
    this.sinks.add(sink)
    return () => {
      this.sinks.delete(sink)
    }
  }
}

export const makeEventFanout: Effect.Effect<EventFanout> = Effect.map(
  PubSub.unbounded<EventEnvelope>({ replay: 256 }),
  (pubsub) => new EventFanout(pubsub)
)

const MAX_PROMPT_ATTACHMENTS = 10
/// Attachment temp files older than this are swept at server start; agents
/// may read a materialized path late in a turn, so nothing is deleted while
/// a session could still reference it.
const ATTACHMENT_TEMP_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

const attachmentsTempRoot = (): string => join(tmpdir(), "codevisor-attachments")

const IMAGE_MAGIC_BYTES: ReadonlyArray<readonly [ReadonlyArray<number>, number]> = [
  [[0x89, 0x50, 0x4e, 0x47], 0], // png
  [[0xff, 0xd8, 0xff], 0], // jpeg
  [[0x47, 0x49, 0x46, 0x38], 0], // gif
  [[0x57, 0x45, 0x42, 0x50], 8] // webp (RIFF....WEBP)
]

/// The stored kind drives UI treatment (thumbnail + lightbox vs file chip)
/// and provider mapping, so it is sniffed server-side rather than trusted
/// from the client's Content-Type alone.
const sniffAttachmentKind = (data: Buffer, mimeType: string): "image" | "file" => {
  const isImage =
    IMAGE_MAGIC_BYTES.some(
      ([magic, offset]) =>
        data.byteLength >= offset + magic.length &&
        magic.every((byte, index) => data[offset + index] === byte)
    ) || mimeType.startsWith("image/")
  return isImage ? "image" : "file"
}

const sanitizeFileName = (name: string): string => {
  // oxlint-disable-next-line no-control-regex
  const cleaned = name.replace(/[/\\:\0]/g, "_").replace(/^\.+/, "")
  return cleaned.length === 0 ? "attachment" : cleaned
}

const readAttachment = async (
  services: CodevisorServerServices,
  fileId: string
): Promise<{ readonly data: Buffer; readonly metadata: FileMetadata }> => {
  const record = await run(services.db.getFileStorage(fileId))
  if (record === undefined) {
    throw new HttpFailure(404, `File not found: ${fileId}`)
  }
  const store = services.attachments
  if (record.storageState !== "sqlite") {
    try {
      return { data: await store.read(record.metadata), metadata: record.metadata }
    } catch (cause) {
      if (record.storageState === "disk") throw cause
      // Dual rows retain their legacy bytes until the disk object has been
      // reverified, so a damaged copy remains recoverable during migration.
    }
  }
  if (
    record.data.byteLength !== record.metadata.sizeBytes ||
    createHash("sha256").update(record.data).digest("hex") !== record.metadata.sha256
  ) {
    throw new AttachmentStoreError(`Attachment bytes are missing or corrupt: ${fileId}`)
  }
  await store.put(record.data, record.metadata.sha256)
  await run(services.db.markFileStorageDual(fileId))
  return { data: record.data, metadata: record.metadata }
}

/// Materializes attachment bytes as temp files so path-based provider inputs
/// (Codex localImage, path notes for arbitrary files) can reference them.
/// Files are immutable, so an existing materialization is reused.
const resolvePromptAttachments = async (
  services: CodevisorServerServices,
  refs: ReadonlyArray<AttachmentRef>
): Promise<Array<PromptAttachmentInput>> => {
  const resolved: Array<PromptAttachmentInput> = []
  for (const ref of refs) {
    let file: Awaited<ReturnType<typeof readAttachment>>
    try {
      file = await readAttachment(services, ref.fileId)
    } catch (cause) {
      if (cause instanceof HttpFailure && cause.status === 404) {
        throw new HttpFailure(422, `Attachment file missing: ${ref.fileId}`)
      }
      throw cause
    }
    const directory = join(attachmentsTempRoot(), ref.fileId)
    mkdirSync(directory, { recursive: true })
    const path = join(directory, sanitizeFileName(ref.name))
    if (!existsSync(path)) {
      writeFileSync(path, file.data)
    }
    resolved.push({ data: file.data, kind: ref.kind, mimeType: ref.mimeType, name: ref.name, path })
  }
  return resolved
}

/// Best-effort start-up sweep of stale materialized attachments; OS tmp
/// reaping is the backstop.
export const sweepAttachmentTempFiles = (now = Date.now()): void => {
  try {
    for (const entry of readdirSync(attachmentsTempRoot())) {
      const path = join(attachmentsTempRoot(), entry)
      try {
        if (now - statSync(path).mtimeMs > ATTACHMENT_TEMP_MAX_AGE_MS) {
          rmSync(path, { force: true, recursive: true })
        }
      } catch {
        // Another process may have removed the entry mid-sweep.
      }
    }
  } catch {
    // The temp root does not exist until the first attachment is resolved.
  }
}

export const defaultServerConfig = (
  overrides: Partial<CodevisorServerConfig> = {}
): CodevisorServerConfig => ({
  id: overrides.id ?? "local",
  name: overrides.name ?? "Local Codevisor",
  version: overrides.version ?? "0.1.0",
  kind: overrides.kind ?? "local",
  host: overrides.host ?? "127.0.0.1",
  port: overrides.port ?? 49361,
  worktreeNameStyle: overrides.worktreeNameStyle ?? "production",
  auth: overrides.auth ?? {
    allowLocalhostWithoutAuth: true,
    requireBearerToken: false
  },
  corsOrigins: overrides.corsOrigins,
  onShutdownRequested: overrides.onShutdownRequested,
  updater: overrides.updater
})

export const makeCodevisorServerApp = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  webSocketServer = new WebSocketServer({ noServer: true })
): CodevisorServerApp => {
  const routeState: RouteState = {
    activePromptSessions: new Set(),
    gatedSessions: new Map(),
    pendingPromptActions: new Set(),
    pendingSessionCreates: new Map()
  }
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
      unsubscribeAuth?.()
      unsubscribeLifecycle?.()
      unsubscribeGate?.()
      webSocketServer.close()
      void services.mcp?.close()
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

export const reconcileOrphanedSessionTurns = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string
): Promise<void> => {
  const sessions = await run(services.db.listSessions)
  for (const session of sessions) {
    if (session.isArchived) {
      // Archived sessions get no turn restoration, but a stale streaming row
      // must still be closed — unarchiving would otherwise resurface it as an
      // endless in-progress turn.
      await run(
        services.db.failStaleAssistantChatItems(
          session.id,
          "The server restarted before this response finished."
        )
      )
      continue
    }
    const page = await run(services.db.getTranscriptPage(session.id, undefined, 1))
    const active = page.items.at(-1)
    const hasOrphanedTurn = active?.role === "assistant" && active.isGenerating
    // Reconciliation runs before the server accepts clients, so no live turn
    // exists anywhere: every streaming row is dead. The newest item is closed
    // by the turn-ending path below with full restore context; older rows —
    // stranded mid-transcript when a previous process died or a concurrent
    // writer stole the projection pointer — would otherwise render as an
    // endless in-progress turn that no future event can ever finish.
    await run(
      services.db.failStaleAssistantChatItems(
        session.id,
        "The server restarted before this response finished.",
        hasOrphanedTurn ? active.id : undefined
      )
    )
    // The database projection always supplies the full background-task
    // snapshot; the API field is optional only for older remote clients.
    const hasOrphanedTasks = page.backgroundTasks!.length > 0
    const claimedPrompts = await run(services.db.listProcessingPromptQueue(session.id))
    const processingPrompts: Array<PromptQueueItem> = []
    for (const item of claimedPrompts) {
      if (await run(services.db.hasTerminalAssistantAfterMessage(session.id, item.id))) {
        // The provider finished and only the queue acknowledgement was lost.
        // Its terminal chat row is sufficient proof that replay is unnecessary.
        await run(services.db.completePromptQueueItem(session.id, item.id))
      } else {
        processingPrompts.push(item)
      }
    }
    if (!hasOrphanedTurn && !hasOrphanedTasks && processingPrompts.length === 0) continue

    // The provider-side resolver vanished with the old process. Pair a
    // persisted question before ending the turn so event replay never leaves
    // an apparently answerable request behind.
    if (hasOrphanedTurn && page.pendingQuestion !== undefined) {
      await appendAndPublish(services.db, fanout, "session.output", session.id, {
        outcome: "cancelled",
        questionId: page.pendingQuestion.questionId,
        questions: page.pendingQuestion.questions,
        sessionUpdate: "question_resolved",
        serverId
      })
    }

    // Process-owned background tasks cannot survive the same crash. Publish a
    // full empty snapshot before the terminal event so another crash can never
    // persist the terminal row while leaving stale work behind. If startup
    // dies between these appends, the still-generating turn is reconciled again.
    if (hasOrphanedTasks) {
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        backgroundTasks: [],
        serverId
      })
    }
    // A prompt remains durably claimed until its provider call finishes. If
    // the process died while dispatching it, make sure the user's input is
    // represented exactly once, then create a deterministic interrupted turn
    // when the provider had not emitted one yet. The claim is acknowledged
    // only after another durable generating row exists, so every crash point
    // leaves at least one marker for the next startup pass to reconcile.
    for (const item of processingPrompts) {
      if (!(await run(services.db.hasConversationMessage(session.id, item.id)))) {
        await appendAndPublish(services.db, fanout, "session.output", session.id, {
          role: "user",
          messageId: item.id,
          text: item.text,
          ...(item.attachments === undefined ? {} : { attachments: item.attachments }),
          serverId
        })
      }
    }

    let terminalTurnId = hasOrphanedTurn ? active.turnId : undefined
    if (!hasOrphanedTurn && processingPrompts.length > 0) {
      terminalTurnId = `recovered-prompt:${processingPrompts[0]!.id}`
      await appendAndPublish(services.db, fanout, "session.updated", session.id, {
        initiatedBy: "user",
        turnId: terminalTurnId,
        turnState: "started",
        serverId
      })
    }
    for (const item of processingPrompts) {
      await run(services.db.completePromptQueueItem(session.id, item.id))
    }

    if (!hasOrphanedTurn && terminalTurnId === undefined) continue

    await appendAndPublish(services.db, fanout, "session.updated", session.id, {
      ...(terminalTurnId === undefined
        ? {}
        : { initiatedBy: "user", turnId: terminalTurnId, turnState: "ended" }),
      serverId,
      stopDetail:
        "The server restarted before this turn finished. Reopen the chat to reconnect its agent session, then send a message to continue.",
      stopReason: "interrupted"
    })
  }
}

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
    applyCorsHeaders(config, request, response)
    if (request.method === "OPTIONS") {
      // Preflight for allowlisted browser origins (the CORS headers above
      // carry the grant); auth is intentionally skipped — preflights never
      // carry credentials, and the actual request is still authorized.
      response.writeHead(204, {
        "Access-Control-Allow-Methods": "GET, POST, PUT, PATCH, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": "Authorization, Content-Type",
        "Access-Control-Max-Age": "86400"
      })
      response.end()
      return
    }
    if (request.method === "GET" && url.pathname === "/v1/health") {
      writeJson(response, 200, { ok: true, version: config.version, database: "ready" })
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

    if (request.method === "GET" && url.pathname === "/v1/info") {
      writeJson(response, 200, {
        id: config.id,
        name: config.name,
        kind: config.kind,
        version: config.version,
        platform: process.platform,
        bindHost: config.host,
        features: ["canonical-chat-v1", "session-event-stream-v1", "transcript-pagination-v1"],
        machineId: await run(services.db.getOrCreateInstanceId),
        arch: process.arch,
        hostname: hostname()
      })
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/openapi.json") {
      writeJson(response, 200, makeOpenApiDocument(config.version))
      return
    }

    if (request.method === "GET" && url.pathname === "/v1/update") {
      if (config.updater !== undefined) {
        writeJson(response, 200, await config.updater.check())
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
      const info = await config.updater.check()
      if (!info.updateAvailable) {
        writeJson(response, 200, { accepted: false, targetVersion: info.currentVersion })
        return
      }
      // Acknowledge first: applying restarts the process, so this response
      // must be on the wire before the server goes away.
      writeJson(response, 202, { accepted: true, targetVersion: info.latestVersion })
      config.updater.apply().catch(() => undefined)
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
    if (await routeWorkspaces(services, fanout, request, response, url)) {
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
    if (await routeSessions(services, fanout, routeState, request, response, url, config)) {
      return
    }
    if (await routeFiles(services, request, response, url)) {
      return
    }
    if (await routeFs(request, response, url)) {
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

/* v8 ignore start -- browser setup routes are exercised by native app integration tests. */
const routeBrowserUse = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (!url.pathname.startsWith("/v1/browser-use")) return false
  const manager = services.mcp
  if (manager === undefined) throw new HttpFailure(501, "Browser Use is unavailable")
  if (url.pathname === "/v1/browser-use" && request.method === "GET") {
    writeJson(response, 200, await manager.browserConfiguration())
    return true
  }
  if (url.pathname === "/v1/browser-use" && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateBrowserUseConfigurationRequestSchema)
    writeJson(
      response,
      200,
      await manager.setBrowserPreference(payload.preferredBrowser ?? undefined)
    )
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/install" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionInstaller())
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/folder" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionFolder())
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/chrome" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionsPage())
    return true
  }
  if (url.pathname === "/v1/browser-use/extension/web-store" && request.method === "POST") {
    writeJson(response, 200, await manager.openBrowserExtensionWebStore())
    return true
  }
  throw new HttpFailure(404, "Browser Use route not found")
}
/* v8 ignore stop */

const routeMcps = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.mcp
  if (!url.pathname.startsWith("/v1/mcps")) return false
  if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")

  if (url.pathname === "/v1/mcps") {
    if (request.method === "GET") {
      writeJson(response, 200, await manager.list())
      return true
    }
    if (request.method === "POST") {
      writeJson(
        response,
        201,
        await manager.create(await readSchema(request, CreateMcpServerRequestSchema))
      )
      return true
    }
  }

  if (url.pathname === "/v1/mcps/detect-auth" && request.method === "POST") {
    const payload = await readSchema(request, DetectMcpAuthRequestSchema)
    writeJson(response, 200, await manager.detectAuth(payload.url))
    return true
  }

  const toolsId = matchRoute(url.pathname, "/v1/mcps/:id/tools")
  if (toolsId !== undefined && request.method === "GET") {
    writeJson(response, 200, await manager.tools(toolsId))
    return true
  }

  const action = matchRouteParams(url.pathname, "/v1/mcps/:id/:action")
  if (action !== undefined && request.method === "POST") {
    switch (action.action) {
      case "connect":
        writeJson(response, 200, await manager.connect(action.id!))
        return true
      case "oauth-start":
        writeJson(response, 201, {
          authorizationUrl: await manager.beginOAuth(action.id!, url.origin)
        })
        return true
      case "oauth-disconnect":
        writeJson(response, 200, await manager.disconnectOAuth(action.id!))
        return true
      default:
        break
    }
  }

  const id = matchRoute(url.pathname, "/v1/mcps/:id")
  if (id !== undefined) {
    if (request.method === "PATCH") {
      const update = await readSchema(request, UpdateMcpServerRequestSchema)
      if (["browser", "computer"].includes(id)) {
        const unsupported = Object.keys(update).filter((key) => key !== "enabled")
        if (unsupported.length > 0) {
          throw new HttpFailure(
            409,
            "Built-in automation providers can only be enabled or disabled"
          )
        }
      }
      writeJson(response, 200, await manager.update(id, update))
      return true
    }
    if (request.method === "DELETE") {
      if (["browser", "computer"].includes(id)) {
        throw new HttpFailure(409, "Built-in automation providers cannot be removed")
      }
      await manager.remove(id)
      writeJson(response, 204, undefined)
      return true
    }
  }
  return false
}

const routeMcpScopes = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.mcp
  const projectRoute = matchRouteParams(url.pathname, "/v1/projects/:id/mcps/:mcpId")
  if (projectRoute !== undefined && request.method === "PATCH") {
    if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
    const payload = await readSchema(request, UpdateMcpServerRequestSchema)
    if (payload.enabled === undefined) throw new HttpFailure(400, "enabled is required")
    writeJson(
      response,
      200,
      await manager.setProjectEnabled(projectRoute.id!, projectRoute.mcpId!, payload.enabled)
    )
    return true
  }
  const sessionRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/mcps/:mcpId")
  if (sessionRoute !== undefined && request.method === "PATCH") {
    if (manager === undefined) throw new HttpFailure(501, "MCP gateway unavailable")
    const payload = await readSchema(request, UpdateMcpServerRequestSchema)
    if (payload.enabled === undefined) throw new HttpFailure(400, "enabled is required")
    const session = await run(services.db.getSessionSummary(sessionRoute.id!))
    writeJson(
      response,
      200,
      await manager.setSessionEnabled(
        session.id,
        sessionRoute.mcpId!,
        payload.enabled,
        session.projectId
      )
    )
    return true
  }
  return false
}

const routeNativeMcps = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.nativeMcp
  if (!url.pathname.startsWith("/v1/native-mcps")) return false
  if (manager === undefined) throw new HttpFailure(501, "Native MCP discovery unavailable")

  if (url.pathname === "/v1/native-mcps" && request.method === "GET") {
    writeJson(response, 200, await manager.scan())
    return true
  }

  if (url.pathname === "/v1/native-mcps/import" && request.method === "POST") {
    writeJson(
      response,
      200,
      await manager.importServers(await readSchema(request, ImportNativeMcpsRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/native-mcps/remove" && request.method === "POST") {
    const payload = await readSchema(request, RemoveNativeMcpRequestSchema)
    writeJson(response, 200, await manager.removeServer(payload.harnessId, payload.serverName))
    return true
  }

  if (url.pathname === "/v1/native-mcps/removals" && request.method === "GET") {
    writeJson(response, 200, await manager.listRemovals())
    return true
  }

  const removalRoute = matchRouteParams(url.pathname, "/v1/native-mcps/removals/:id/:action")
  if (
    removalRoute !== undefined &&
    removalRoute.action === "restore" &&
    request.method === "POST"
  ) {
    writeJson(response, 200, await manager.restoreRemoval(removalRoute.id!))
    return true
  }

  if (url.pathname === "/v1/native-mcps/set-enabled" && request.method === "POST") {
    const payload = await readSchema(request, SetNativeMcpEnabledRequestSchema)
    writeJson(
      response,
      200,
      await manager.setNativeEnabled(payload.harnessId, payload.serverName, payload.enabled)
    )
    return true
  }
  return false
}

const routeSkills = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const manager = services.skills
  if (!url.pathname.startsWith("/v1/skills")) return false
  if (manager === undefined) throw new HttpFailure(501, "Skills management unavailable")

  if (url.pathname === "/v1/skills") {
    if (request.method === "GET") {
      writeJson(response, 200, await manager.list())
      return true
    }
    if (request.method === "POST") {
      writeJson(
        response,
        201,
        await manager.create(await readSchema(request, CreateSkillRequestSchema))
      )
      return true
    }
  }

  if (url.pathname === "/v1/skills/import" && request.method === "POST") {
    writeJson(
      response,
      201,
      await manager.importLocal(await readSchema(request, ImportSkillRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/skills/import-remote" && request.method === "POST") {
    writeJson(
      response,
      201,
      await manager.importRemote(await readSchema(request, ImportRemoteSkillRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/skills/discover-remote" && request.method === "POST") {
    writeJson(
      response,
      200,
      await manager.discoverRemote(await readSchema(request, DiscoverRemoteSkillsRequestSchema))
    )
    return true
  }

  if (url.pathname === "/v1/skills/make-global" && request.method === "POST") {
    const payload = await readSchema(request, MakeSkillGlobalRequestSchema)
    writeJson(response, 200, await manager.makeGlobal(payload.harnessId, payload.directoryName))
    return true
  }

  if (url.pathname === "/v1/skills/sync" && request.method === "POST") {
    writeJson(response, 200, await manager.sync(await readSchema(request, SyncSkillsRequestSchema)))
    return true
  }

  const installRoute = matchRouteParams(url.pathname, "/v1/skills/:name/harnesses/:harnessId")
  if (installRoute !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, SetSkillInstalledRequestSchema)
    writeJson(
      response,
      200,
      await manager.setInstalled(installRoute.name!, installRoute.harnessId!, payload.installed)
    )
    return true
  }

  const name = matchRoute(url.pathname, "/v1/skills/:name")
  if (name !== undefined && request.method === "DELETE") {
    writeJson(response, 200, await manager.remove(name))
    return true
  }
  return false
}

const routeProjects = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const serverId = config.id
  if (request.method === "GET" && url.pathname === "/v1/projects") {
    const projects = await run(services.db.listProjects)
    writeJson(
      response,
      200,
      await Promise.all(projects.map((project) => probeProject(serverId, project)))
    )
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/projects") {
    const project = await run(
      services.db.createProject(await readSchema(request, CreateProjectRequestSchema))
    )
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
    writeJson(response, 201, await probeProject(serverId, project))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/projects/from-git") {
    const payload = await readSchema(request, CreateProjectFromGitRequestSchema)
    const repoUrl = payload.url.trim()
    if (!looksLikeGitUrl(repoUrl)) {
      throw new HttpFailure(400, `Not a git URL: ${payload.url}`, "invalid_url")
    }
    const name = payload.name?.trim() || cloneDirectoryName(repoUrl)
    if (name === undefined || name.length === 0) {
      throw new HttpFailure(
        400,
        "Could not derive a project name from the URL; pass one explicitly",
        "invalid_url"
      )
    }
    const destination = managedRepoPath(name)
    if (existsSync(destination)) {
      throw new HttpFailure(
        409,
        `${destination} already exists on this machine; add it as a local directory instead`,
        "already_exists"
      )
    }

    const newProjectId = payload.id ?? randomUUID()
    const publishSetup = makeProjectSetupPublisher(services.db, fanout, newProjectId, repoUrl)
    const startedAt = Date.now()
    await publishSetup({ state: "started" })
    try {
      mkdirSync(dirname(destination), { recursive: true })
      await cloneRepository(repoUrl, destination, (stream, line) => {
        void publishSetup({ state: "log", stream, line })
      })
      await publishSetup({ state: "completed", durationMs: Date.now() - startedAt })
    } catch (cause) {
      /* v8 ignore next -- cloneRepository always throws CloneError; the fallback guards mkdir failures. */
      const code = cause instanceof CloneError ? cause.code : undefined
      await publishSetup({
        state: "failed",
        message: failureMessage(cause),
        /* v8 ignore next -- spawn-level clone failures carry no classification; exercised directly in git.test.ts. */
        ...(code === undefined ? {} : { code }),
        durationMs: Date.now() - startedAt
      })
      // Never leave a partial checkout behind: the name must be retryable.
      /* v8 ignore next -- best-effort cleanup; a second fault still surfaces the git error. */
      rmSync(destination, { force: true, recursive: true })
      throw cause
    }

    const project = await run(
      services.db.createProject({
        id: newProjectId,
        folderPath: destination,
        name,
        repoUrl
      })
    )
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
    writeJson(response, 201, await probeProject(serverId, project))
    return true
  }

  const projectId = matchRoute(url.pathname, "/v1/projects/:id")
  if (projectId !== undefined && request.method === "PATCH") {
    const project = await run(
      services.db.updateProject(projectId, await readSchema(request, UpdateProjectRequestSchema))
    )
    await appendAndPublish(services.db, fanout, "project.updated", project.id, project)
    writeJson(response, 200, await probeProject(serverId, project))
    return true
  }

  if (projectId !== undefined && request.method === "DELETE") {
    await run(services.db.deleteProject(projectId))
    await appendAndPublish(services.db, fanout, "project.deleted", projectId, {
      id: projectId
    })
    writeJson(response, 204, undefined)
    return true
  }

  const worktreeProjectId = matchRoute(url.pathname, "/v1/projects/:id/worktrees")
  if (worktreeProjectId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.listWorktrees(worktreeProjectId)))
    return true
  }

  if (worktreeProjectId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, CreateWorktreeRequestSchema)
    const project = await getProjectOrFail(services.db, worktreeProjectId)
    const location = localLocationOrFail(serverId, project)
    assertLocationFolderExists(location)
    if (!(await isGitWorkTree(location.folderPath))) {
      throw new HttpFailure(422, `Project folder is not a git repository: ${location.folderPath}`)
    }
    // Server data/worktree directories may be isolated, but local branches
    // belong to the shared Git repository. Include both namespaces so an
    // archived worktree or another development server cannot look available.
    const existing = new Set((await run(services.db.listWorktrees(project.id))).map((w) => w.name))
    for (const name of await listCodevisorWorktreeBranchNames(location.folderPath)) {
      existing.add(name)
    }
    const requested = slugifyWorktreeName(payload.name)
    // Refresh once, outside the collision loop. The ref check above handles
    // established conflicts; retrying `git worktree add -b` handles the race
    // where another isolated server claims the same branch after our scan.
    const startPoint = await worktreeStartPoint(location.folderPath)
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const name =
        config.worktreeNameStyle === "development"
          ? availableDevelopmentWorktreeName(existing)
          : requested === undefined
            ? availableProductionWorktreeName(existing)
            : availableWorktreeName(requested, existing)
      const branch = `codevisor/${name}`
      let worktree: Worktree
      try {
        worktree = await run(services.db.createWorktree(project.id, name, branch, payload.id))
      } catch (cause) {
        // A concurrent request on this server can reserve the candidate after
        // our initial scan. Retry only the name constraint; a duplicate
        // client-supplied id or any other database failure is not recoverable
        // by changing the branch name.
        /* v8 ignore start -- requires a deterministic interleaving inside the database's atomic unique constraint. */
        if (isWorktreeNameCollision(cause) && attempt < 99) {
          existing.add(name)
          continue
        }
        throw cause
        /* v8 ignore stop */
      }
      const startedAt = Date.now()
      const publishSetup = makeWorktreeSetupPublisher(
        services.db,
        fanout,
        worktree,
        payload.sessionId
      )
      await publishSetup({ state: "started" })
      try {
        mkdirSync(dirname(worktree.path), { recursive: true })
        await addWorktree(
          location.folderPath,
          worktree.path,
          branch,
          (stream, line) => {
            void publishSetup({ state: "log", stream, line })
          },
          startPoint
        )
        await publishSetup({ state: "completed", durationMs: Date.now() - startedAt })
      } catch (cause) {
        // Release the reservation before retrying the same client-supplied id
        // under a new name. Only a branch collision is retryable; other Git
        // failures retain their terminal setup event and original response.
        /* v8 ignore start -- requires another process to claim a branch between the preflight scan and git worktree add. */
        await run(services.db.deleteWorktree(worktree.id)).catch(() => undefined)
        if (isWorktreeBranchCollision(cause) && attempt < 99) {
          existing.add(name)
          await publishSetup({
            state: "log",
            stream: "stderr",
            line: `Branch ${branch} was claimed concurrently; choosing another name.`
          })
          continue
        }
        await publishSetup({
          state: "failed",
          message: failureMessage(cause),
          durationMs: Date.now() - startedAt
        })
        throw cause
        /* v8 ignore stop */
      }
      await appendAndPublish(services.db, fanout, "worktree.created", worktree.id, worktree)
      writeJson(response, 201, worktree)
      return true
    }
    /* v8 ignore next -- the allocator's candidate bound guarantees a free name before 100 attempts absent continuous external races. */
    throw new HttpFailure(422, "Unable to allocate an unused Git worktree branch")
  }

  return false
}

/// Pane workspaces are client-authored identity records, so writes are
/// idempotent PUTs keyed by the client's workspace id. Creates and updates
/// share one `workspace.updated` event to keep client mirroring simple.
/// Workspace notes follow the same shape: one PUT-replaced row per workspace
/// whose `workspace.notes.updated` event carries the full record so clients
/// can live-apply it without a refetch.
const routeWorkspaces = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/workspaces") {
    writeJson(response, 200, await run(services.db.listWorkspaces))
    return true
  }

  const notesWorkspaceId = matchRoute(url.pathname, "/v1/workspaces/:id/notes")
  if (notesWorkspaceId !== undefined && request.method === "GET") {
    const notes = await run(services.db.getWorkspaceNotes(notesWorkspaceId))
    if (notes === undefined) {
      // Clients treat this 404 as "no notes yet" rather than an error.
      throw new HttpFailure(404, `Workspace notes not found: ${notesWorkspaceId}`)
    }
    writeJson(response, 200, notes)
    return true
  }

  if (notesWorkspaceId !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspaceNotesRequestSchema)
    const notes = await run(
      services.db.saveWorkspaceNotes({ ...payload, workspaceId: notesWorkspaceId })
    )
    await appendAndPublish(services.db, fanout, "workspace.notes.updated", notesWorkspaceId, notes)
    writeJson(response, 200, notes)
    return true
  }

  const workspaceId = matchRoute(url.pathname, "/v1/workspaces/:id")
  if (workspaceId !== undefined && request.method === "PUT") {
    const payload = await readSchema(request, UpsertWorkspaceRequestSchema)
    if (payload.id !== undefined && payload.id !== workspaceId) {
      throw new HttpFailure(
        400,
        `Workspace id in the body (${payload.id}) does not match the path (${workspaceId})`
      )
    }
    const workspace = await run(services.db.upsertWorkspace({ ...payload, id: workspaceId }))
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
    writeJson(response, 200, workspace)
    return true
  }

  if (workspaceId !== undefined && request.method === "DELETE") {
    await run(services.db.deleteWorkspace(workspaceId))
    await appendAndPublish(services.db, fanout, "workspace.deleted", workspaceId, {
      id: workspaceId
    })
    writeJson(response, 204, undefined)
    return true
  }

  return false
}

const slugifyWorktreeName = (name: string | undefined): string | undefined => {
  const slug = (name ?? "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 64)
    .replace(/-+$/g, "")
  return slug.length > 0 ? slug : undefined
}

/// Keeps explicit names readable and only adds a sequence number when the
/// requested name is already in use. The upper bound guarantees a free name:
/// existing.size + 1 distinct candidates cannot all appear in `existing`.
const availableWorktreeName = (base: string, existing: ReadonlySet<string>): string => {
  if (!existing.has(base)) {
    return base
  }
  for (let number = 2; number <= existing.size + 2; number += 1) {
    const suffix = `-${number}`
    const stem = base.slice(0, 64 - suffix.length).replace(/-+$/g, "")
    const candidate = `${stem}${suffix}`
    if (!existing.has(candidate)) {
      return candidate
    }
  }
  /* v8 ignore next -- existing.size + 1 candidates guarantee a free suffix. */
  throw new Error("Unable to allocate a unique worktree name")
}

/* v8 ignore start -- exercised only by the deliberately timing-dependent database race above. */
const isWorktreeNameCollision = (cause: unknown): boolean =>
  cause instanceof DatabaseError &&
  cause.operation === "createWorktree" &&
  cause.message.includes(
    "UNIQUE constraint failed: worktrees.project_id, worktrees.server_id, worktrees.name"
  )
/* v8 ignore stop */

type WorktreeSetupDetail = Omit<WorktreeSetupUpdate, "worktreeId" | "projectId" | "name" | "branch">

/// Publishes `worktree.setup` progress events (subjectId = worktree id),
/// serialized on a promise chain so streamed log lines and lifecycle updates
/// land in the event log in emission order. Returned promises resolve once
/// that update is durable; failures surface to awaited call sites without
/// stalling later updates.
/// Directory listing for the remote project picker. Directories only —
/// choosing a project means choosing a folder — with a git badge so existing
/// checkouts stand out. Requires the caller's bearer token like every other
/// data route; the response deliberately exposes nothing but names.
const routeFs = async (
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "GET" || url.pathname !== "/v1/fs/list") {
    return false
  }
  const requested = url.searchParams.get("path") ?? "~"
  const showHidden = url.searchParams.get("showHidden") === "true"
  const home = homedir()
  const expanded =
    requested === "~"
      ? home
      : requested.startsWith("~/")
        ? join(home, requested.slice(2))
        : requested
  if (!expanded.startsWith("/")) {
    throw new HttpFailure(400, `Path must be absolute: ${requested}`, "invalid_path")
  }
  const path = resolvePath(expanded)
  let names: Array<import("node:fs").Dirent>
  try {
    names = await readdir(path, { withFileTypes: true })
  } catch (cause) {
    /* v8 ignore next -- readdir errno failures always carry a code. */
    const code = (cause as NodeJS.ErrnoException).code ?? ""
    if (code === "ENOENT") {
      throw new HttpFailure(404, `No such directory: ${path}`, "not_found")
    }
    if (["EACCES", "EPERM"].includes(code)) {
      throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
    }
    /* v8 ignore start -- the not-ENOTDIR arm covers other readdir failures (EIO etc.) falling through to the generic 500. */
    if (code === "ENOTDIR") {
      throw new HttpFailure(400, `Not a directory: ${path}`, "not_a_directory")
    }
    throw cause
    /* v8 ignore stop */
  }
  const entries = names
    .filter((entry) => {
      if (!showHidden && entry.name.startsWith(".")) return false
      if (entry.isDirectory()) return true
      // Follow directory symlinks (common for workspace layouts); skip broken ones.
      if (!entry.isSymbolicLink()) return false
      try {
        return statSync(join(path, entry.name)).isDirectory()
      } catch {
        return false
      }
    })
    .map((entry) => ({
      name: entry.name,
      path: join(path, entry.name),
      isGitRepo: existsSync(join(path, entry.name, ".git"))
    }))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: "base" }))
  const body: FsListResponse = {
    path,
    parent: path === "/" ? null : dirname(path),
    entries
  }
  writeJson(response, 200, body)
  return true
}

/// Serialized project.setup progress for clone-from-git, mirroring the
/// worktree.setup pattern: clients follow the client-supplied project id on
/// the event stream while the HTTP request is still in flight.
const makeProjectSetupPublisher = (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  projectId: string,
  repoUrl: string
): ((
  detail: Partial<ProjectSetupUpdate> & { state: ProjectSetupUpdate["state"] }
) => Promise<void>) => {
  let chain: Promise<void> = Promise.resolve()
  return (detail) => {
    const update: ProjectSetupUpdate = {
      projectId,
      url: repoUrl,
      ...detail
    }
    const next = chain.then(async () => {
      await appendAndPublish(db, fanout, "project.setup", projectId, update)
    })
    /* v8 ignore next -- keeps the chain alive if the event log write fails; awaited callers still see the failure via `next`. */
    chain = next.catch(() => undefined)
    return next
  }
}

/// Derives the managed checkout directory name from the remote URL
/// ("git@github.com:acme/widget.git" → "widget").
const cloneDirectoryName = (url: string): string | undefined => {
  const trimmed = url.trim().replace(/\/+$/, "")
  /* v8 ignore next -- a URL that passed looksLikeGitUrl always has at least one non-separator segment. */
  const last = trimmed.split(/[/:]/).filter(Boolean).at(-1) ?? ""
  const name = last.replace(/\.git$/i, "")
  return /^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name) ? name : undefined
}

const looksLikeGitUrl = (url: string): boolean =>
  /^(https?:\/\/|git:\/\/|ssh:\/\/)[^\s]+$/.test(url) ||
  /^[\w.-]+@[\w.-]+:[^\s]+$/.test(url) ||
  url.startsWith("file://")

const makeWorktreeSetupPublisher = (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  worktree: Worktree,
  mirrorSubjectId?: string
): ((detail: WorktreeSetupDetail) => Promise<void>) => {
  let chain: Promise<void> = Promise.resolve()
  return (detail) => {
    const update: WorktreeSetupUpdate = {
      worktreeId: worktree.id,
      projectId: worktree.projectId,
      name: worktree.name,
      branch: worktree.branch,
      ...detail
    }
    const next = chain.then(async () => {
      await appendAndPublish(db, fanout, "worktree.setup", worktree.id, update)
      if (mirrorSubjectId !== undefined) {
        await appendAndPublish(db, fanout, "worktree.setup", mirrorSubjectId, update)
      }
    })
    /* v8 ignore next -- keeps the chain alive if the event log write fails; awaited callers still see the failure via `next`. */
    chain = next.catch(() => undefined)
    return next
  }
}

/// Annotates this server's locations with whether their folder is a git
/// repository so clients can decide if the worktree option is available.
const probeProject = async (serverId: string, project: Project): Promise<Project> => ({
  ...project,
  locations: await Promise.all(
    project.locations.map(async (location) =>
      location.serverId === serverId && existingDirectory(location.folderPath) !== undefined
        ? { ...location, isGitRepository: await isGitWorkTree(location.folderPath) }
        : location
    )
  )
})

const routeHarnesses = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const openCodeProviders = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/accounts/:accountId/providers"
  )
  if (openCodeProviders !== undefined && request.method === "GET") {
    if (services.auth?.openCodeProviders === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    writeJson(response, 200, await services.auth.openCodeProviders(openCodeProviders.accountId!))
    return true
  }

  const openCodeProviderLogin = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId/login"
  )
  if (openCodeProviderLogin !== undefined && request.method === "POST") {
    if (services.auth?.beginOpenCodeLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, StartOpenCodeAuthRequestSchema)
    writeJson(
      response,
      201,
      await services.auth.beginOpenCodeLogin(
        openCodeProviderLogin.accountId!,
        openCodeProviderLogin.providerId!,
        payload.methodId,
        payload.inputs,
        payload.apiKey
      )
    )
    return true
  }

  const openCodeProvider = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/accounts/:accountId/providers/:providerId"
  )
  if (openCodeProvider !== undefined && request.method === "DELETE") {
    if (services.auth?.logoutOpenCodeProvider === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    await services.auth.logoutOpenCodeProvider(
      openCodeProvider.accountId!,
      openCodeProvider.providerId!
    )
    writeJson(response, 204, undefined)
    return true
  }

  const openCodeFlowAnswer = matchRouteParams(
    url.pathname,
    "/v1/harnesses/opencode/auth-flows/:flowId/answer"
  )
  if (openCodeFlowAnswer !== undefined && request.method === "POST") {
    if (services.auth?.answerOpenCodeLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, AnswerOpenCodeAuthRequestSchema)
    writeJson(
      response,
      200,
      await services.auth.answerOpenCodeLogin(openCodeFlowAnswer.flowId!, payload.code)
    )
    return true
  }

  const openCodeFlow = matchRouteParams(url.pathname, "/v1/harnesses/opencode/auth-flows/:flowId")
  if (openCodeFlow !== undefined) {
    if (
      services.auth?.openCodeLoginFlow === undefined ||
      services.auth.cancelOpenCodeLogin === undefined
    ) {
      throw new HttpFailure(501, "Harness authentication unavailable")
    }
    if (request.method === "GET") {
      writeJson(response, 200, services.auth.openCodeLoginFlow(openCodeFlow.flowId!))
      return true
    }
    if (request.method === "DELETE") {
      services.auth.cancelOpenCodeLogin(openCodeFlow.flowId!)
      writeJson(response, 204, undefined)
      return true
    }
  }

  if (url.pathname === "/v1/harnesses/pi/providers" && request.method === "GET") {
    if (services.auth?.piProviders === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    writeJson(response, 200, await services.auth.piProviders())
    return true
  }

  const piProviderLogin = matchRouteParams(
    url.pathname,
    "/v1/harnesses/pi/providers/:providerId/login"
  )
  if (piProviderLogin !== undefined && request.method === "POST") {
    if (services.auth?.beginPiLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, StartPiAuthRequestSchema)
    writeJson(
      response,
      201,
      await services.auth.beginPiLogin(piProviderLogin.providerId!, payload.method)
    )
    return true
  }

  const piProvider = matchRouteParams(url.pathname, "/v1/harnesses/pi/providers/:providerId")
  if (piProvider !== undefined && request.method === "DELETE") {
    if (services.auth?.logoutPiProvider === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    await services.auth.logoutPiProvider(piProvider.providerId!)
    writeJson(response, 204, undefined)
    return true
  }

  const piFlowAnswer = matchRouteParams(url.pathname, "/v1/harnesses/pi/auth-flows/:flowId/answer")
  if (piFlowAnswer !== undefined && request.method === "POST") {
    if (services.auth?.answerPiLogin === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const payload = await readSchema(request, AnswerPiAuthRequestSchema)
    writeJson(response, 200, await services.auth.answerPiLogin(piFlowAnswer.flowId!, payload.value))
    return true
  }

  const piFlow = matchRouteParams(url.pathname, "/v1/harnesses/pi/auth-flows/:flowId")
  if (piFlow !== undefined) {
    if (request.method === "GET") {
      if (services.auth?.piLoginFlow === undefined)
        throw new HttpFailure(501, "Harness authentication unavailable")
      writeJson(response, 200, services.auth.piLoginFlow(piFlow.flowId!))
      return true
    }
    if (request.method === "DELETE") {
      if (services.auth?.cancelPiLogin === undefined)
        throw new HttpFailure(501, "Harness authentication unavailable")
      services.auth.cancelPiLogin(piFlow.flowId!)
      writeJson(response, 204, undefined)
      return true
    }
  }

  if (request.method === "POST" && url.pathname === "/v1/harnesses/auth/refresh") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const harnessId = url.searchParams.get("harnessId")?.trim() || undefined
    await services.auth.refresh(harnessId)
    // Settings consumes this — keep lifecycle fields so a sign-in doesn't
    // wipe the row's update state.
    writeJson(
      response,
      200,
      await discoverHarnesses(services, harnessId === undefined, harnessId, true)
    )
    return true
  }

  if (request.method === "GET" && url.pathname === "/v1/harnesses") {
    const includeLifecycle = url.searchParams.get("include") === "lifecycle"
    writeJson(response, 200, await discoverHarnesses(services, false, undefined, includeLifecycle))
    return true
  }

  // Re-resolves the runtime's PATH (login-shell probe) before re-detecting,
  // so a CLI installed after server start is found without a restart.
  if (request.method === "POST" && url.pathname === "/v1/harnesses/rescan") {
    await run(services.agents.refreshEnvironment)
    writeJson(response, 200, await discoverHarnesses(services, true, undefined, true))
    return true
  }

  // Forced latest-version check for every installed harness, then the
  // refreshed list (blocking rescan pattern — checks are cheap fetches).
  if (request.method === "POST" && url.pathname === "/v1/harnesses/check-updates") {
    if (services.lifecycle === undefined)
      throw new HttpFailure(501, "Harness update checks unavailable")
    await services.lifecycle.checkForUpdates(true)
    writeJson(response, 200, await discoverHarnesses(services, false, undefined, true))
    return true
  }

  // One-click install: 202-ack, work runs in the background, progress via
  // harness.lifecycle.updated events + the attachable output terminal.
  const installHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/install")
  if (installHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness install unavailable")
    const body = (await readJson(request)) as { readonly methodId?: string }
    const methodId = typeof body.methodId === "string" ? body.methodId : undefined
    try {
      const { terminalId } = await services.lifecycle.beginInstall(installHarnessId, methodId)
      writeJson(response, 202, { accepted: true, terminalId })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // Dual-install: the bundled desktop app's version/update state, computed
  // on demand (detail sheet), and its explicit update action.
  const bundledAppHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/bundled-app")
  if (bundledAppHarnessId !== undefined && request.method === "GET") {
    if (services.lifecycle === undefined)
      throw new HttpFailure(501, "Harness update checks unavailable")
    const info = await services.lifecycle.bundledAppInfo(bundledAppHarnessId).catch(swallowError)
    if (info === undefined) throw new HttpFailure(404, "No bundled desktop app")
    writeJson(response, 200, info)
    return true
  }
  const bundledAppUpdateHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/bundled-app/update")
  if (bundledAppUpdateHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined)
      throw new HttpFailure(501, "Harness update checks unavailable")
    try {
      await services.lifecycle.beginBundledAppUpdate(bundledAppUpdateHarnessId)
      writeJson(response, 202, { accepted: true })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // Pending-update controls: "Update Now" skips the idle wait; DELETE
  // disarms a queued update entirely.
  const pendingApplyHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update/pending/apply")
  if (pendingApplyHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
    try {
      await services.lifecycle.forcePendingUpdate(pendingApplyHarnessId)
      writeJson(response, 202, { accepted: true })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }
  const pendingCancelHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update/pending")
  if (pendingCancelHarnessId !== undefined && request.method === "DELETE") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
    try {
      await services.lifecycle.cancelPendingUpdate(pendingCancelHarnessId)
      writeJson(response, 204, undefined)
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // One-click update for CLI harnesses (origin-matched vendor flow).
  const updateHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/update")
  if (updateHarnessId !== undefined && request.method === "POST") {
    if (services.lifecycle === undefined) throw new HttpFailure(501, "Harness update unavailable")
    try {
      const outcome = await services.lifecycle.beginUpdate(updateHarnessId)
      writeJson(response, 202, { accepted: true, ...outcome })
    } catch (cause) {
      throw conflictFrom(cause)
    }
    return true
  }

  // User-defined custom ACP harnesses (~/.codevisor/harnesses.json).
  if (
    url.pathname === "/v1/harnesses/custom" &&
    (request.method === "GET" || request.method === "PUT")
  ) {
    if (services.customHarnesses === undefined)
      throw new HttpFailure(501, "Custom harnesses unavailable")
    if (request.method === "GET") {
      writeJson(response, 200, { harnesses: await services.customHarnesses.list() })
      return true
    }
    // Whole-list replace: the file is the source of truth and stays
    // hand-editable, so the API rewrites it rather than patching entries.
    {
      const body = await readJson(request)
      const parsed = parseCustomHarnessDocument(body, "request body")
      if (parsed.warnings.length > 0) {
        // Reject instead of skipping: the API must never persist entries the
        // next boot would drop.
        throw new HttpFailure(400, parsed.warnings.join("; "))
      }
      await services.customHarnesses.replace(parsed.specs)
      writeJson(response, 200, await discoverHarnesses(services, true, undefined, true))
      return true
    }
  }

  // One-shot ACP initialize handshake for a (possibly unsaved) custom spec —
  // the "Test Connection" action. Blocking with the store's own timeout.
  if (request.method === "POST" && url.pathname === "/v1/harnesses/custom/test") {
    if (services.customHarnesses === undefined)
      throw new HttpFailure(501, "Custom harnesses unavailable")
    const body = await readJson(request)
    const parsed = parseCustomHarnessDocument([body], "request body")
    const spec = parsed.specs[0]
    if (spec === undefined) {
      /* v8 ignore next -- the single-entry wrapper always yields a warning when the spec is invalid. */
      throw new HttpFailure(400, parsed.warnings.join("; ") || "Invalid custom harness spec")
    }
    writeJson(response, 200, await services.customHarnesses.test(spec))
    return true
  }

  // Sessions from the harness's own on-disk store (run before/outside
  // Codevisor) — onboarding workspace suggestions and chat import read these,
  // NOT Codevisor's sessions table (empty on a fresh install by definition).
  const agentSessionsHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/agent-sessions")
  if (agentSessionsHarnessId !== undefined && request.method === "GET") {
    const account = await services.auth?.activeAccountContext(agentSessionsHarnessId)
    writeJson(
      response,
      200,
      await run(services.agents.listAgentSessions(agentSessionsHarnessId, account))
    )
    return true
  }

  const accountLoginCancel = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/login/:flowId"
  )
  if (accountLoginCancel !== undefined && request.method === "DELETE") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    await services.auth.cancelLogin(accountLoginCancel.flowId!)
    writeJson(response, 204, undefined)
    return true
  }

  const accountAction = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/:action"
  )
  if (accountAction !== undefined && request.method === "POST") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    const harnessId = accountAction.id!
    const accountId = accountAction.accountId!
    switch (accountAction.action) {
      case "activate":
        await services.auth.activateAccount(harnessId, accountId)
        writeJson(response, 200, await services.auth.accounts(harnessId))
        return true
      case "login": {
        const payload = await readSchema(request, StartHarnessLoginRequestSchema)
        writeJson(
          response,
          201,
          await services.auth.beginLogin(accountId, payload.methodId, payload.apiKey)
        )
        return true
      }
      case "logout":
        writeJson(response, 200, await services.auth.logout(accountId))
        return true
      default:
        break
    }
  }

  const accountProbe = matchRouteParams(
    url.pathname,
    "/v1/harnesses/:id/accounts/:accountId/auth/probe"
  )
  if (accountProbe !== undefined && request.method === "POST") {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    writeJson(response, 200, await services.auth.probeAccount(accountProbe.accountId!, true))
    return true
  }

  const accountRoute = matchRouteParams(url.pathname, "/v1/harnesses/:id/accounts/:accountId")
  if (accountRoute !== undefined) {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    if (request.method === "PATCH") {
      const payload = await readSchema(request, UpdateHarnessAccountRequestSchema)
      if (payload.label === undefined) throw new HttpFailure(400, "Account label is required")
      writeJson(
        response,
        200,
        await services.auth.renameAccount(accountRoute.accountId!, payload.label)
      )
      return true
    }
    if (request.method === "DELETE") {
      await services.auth.removeAccount(accountRoute.accountId!)
      writeJson(response, 204, undefined)
      return true
    }
  }

  const accountsHarnessId = matchRoute(url.pathname, "/v1/harnesses/:id/accounts")
  if (accountsHarnessId !== undefined) {
    if (services.auth === undefined)
      throw new HttpFailure(501, "Harness authentication unavailable")
    if (request.method === "GET") {
      writeJson(response, 200, await services.auth.accounts(accountsHarnessId))
      return true
    }
    if (request.method === "POST") {
      const payload = await readSchema(request, CreateHarnessAccountRequestSchema)
      writeJson(response, 201, await services.auth.createAccount(accountsHarnessId, payload.label))
      return true
    }
  }

  const harnessId = matchRoute(url.pathname, "/v1/harnesses/:id")
  if (harnessId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateHarnessRequestSchema)
    if (payload.enabled && services.auth !== undefined) {
      const candidate = (await discoverHarnesses(services, true)).find(
        (harness) => harness.id === harnessId
      )
      const state = candidate?.auth?.state
      if (state !== "authenticated" && state !== "notRequired") {
        throw new HttpFailure(409, "Sign in before enabling this harness")
      }
    }
    await run(services.db.setHarnessEnabled(harnessId, payload.enabled))
    const harness = (await discoverHarnesses(services)).find(
      (candidate) => candidate.id === harnessId
    )
    if (harness === undefined) {
      throw new HttpFailure(404, `Harness not found: ${harnessId}`)
    }
    writeJson(response, 200, harness)
    return true
  }

  return false
}

const discoverCapabilities = async (
  services: CodevisorServerServices,
  url: URL
): Promise<{ readonly harnesses: ReadonlyArray<HarnessCapability> }> => {
  const cwd = existingDirectory(url.searchParams.get("cwd")) ?? tmpdir()
  // Existing chats already know their harness. Filtering before auth
  // decoration and inspection is important: both stages can start real CLI
  // processes, so inspecting the whole catalog would put unrelated agents on
  // the resumed chat's critical path.
  const requestedHarnessId = url.searchParams.get("harnessId")?.trim() || undefined
  const harnesses = await discoverHarnesses(services, false, requestedHarnessId)
  const readyHarnesses = harnesses.filter(
    (harness) => harness.enabled && harness.readiness.state === "ready"
  )
  return {
    harnesses: await Promise.all(
      readyHarnesses.map(async (harness) => {
        try {
          const account = await services.auth?.activeAccountContext(harness.id)
          const metadata = await run(services.agents.inspectHarness(harness.id, cwd, account))
          return {
            harness,
            ...(metadata.modes === undefined ? {} : { modes: metadata.modes }),
            configOptions: metadata.configOptions,
            ...(metadata.supportsGoals === undefined
              ? {}
              : { supportsGoals: metadata.supportsGoals })
          }
        } catch {
          return {
            harness,
            configOptions: []
          }
        }
      })
    )
  }
}

const routeSessions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: CodevisorServerConfig
): Promise<boolean> => {
  if (request.method === "GET" && url.pathname === "/v1/sessions") {
    writeJson(response, 200, await run(services.db.listSessions))
    return true
  }

  if (request.method === "POST" && url.pathname === "/v1/sessions") {
    const payload = await readSchema(request, CreateSessionRequestSchema)
    const { session, created } = await createSessionIfMissing(
      services,
      fanout,
      routeState,
      config,
      payload
    )
    writeJson(response, created ? 201 : 200, session)
    return true
  }

  const branchDiffSessionId = matchRoute(url.pathname, "/v1/sessions/:id/branch-diff")
  if (branchDiffSessionId !== undefined && request.method === "GET") {
    const session = await findSession(services.db, branchDiffSessionId)
    if (session === undefined) throw new HttpFailure(404, "Session not found")
    const project = await getProjectOrFail(services.db, session.projectId)
    const directory =
      session.cwd ??
      project.locations.find((location) => location.serverId === session.serverId)?.folderPath
    writeJson(
      response,
      200,
      directory == null ? null : ((await gitBranchDiffTotals(directory)) ?? null)
    )
    return true
  }

  const usageLimitsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/usage-limits")
  if (usageLimitsSessionId !== undefined && request.method === "GET") {
    const session = await findSession(services.db, usageLimitsSessionId)
    if (session === undefined) throw new HttpFailure(404, "Session not found")
    const project = await getProjectOrFail(services.db, session.projectId)
    const cwd =
      session.cwd ??
      project.locations.find((location) => location.serverId === session.serverId)?.folderPath
    if (cwd === undefined) {
      const unavailable: HarnessUsageLimits = {
        detail: "This session has no local workspace from which to query its harness.",
        fetchedAt: new Date().toISOString(),
        harnessId: session.harnessId,
        state: "unavailable",
        windows: []
      }
      writeJson(response, 200, unavailable)
      return true
    }
    const accountContext =
      session.harnessAccountId === undefined
        ? await services.auth?.activeAccountContext(session.harnessId)
        : await services.auth?.accountContext(session.harnessAccountId)
    const limits = await run(
      services.agents.readHarnessUsageLimits(session.harnessId, cwd, accountContext)
    )
    const accountId = session.harnessAccountId ?? accountContext?.id
    const accounts = await services.auth?.accounts(session.harnessId)
    const account = accounts?.find((candidate) => candidate.id === accountId)
    writeJson(response, 200, {
      ...limits,
      ...(accountId === undefined ? {} : { accountId }),
      ...(account === undefined ? {} : { accountEmail: account.email, accountLabel: account.label })
    })
    return true
  }

  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id")
  if (sessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.getSessionDetail(sessionId)))
    return true
  }

  if (sessionId !== undefined && request.method === "PATCH") {
    const payload = await readSchema(request, UpdateSessionRequestSchema)
    const session = await applySessionUpdate(services, fanout, config, sessionId, payload)
    writeJson(response, 200, session)
    return true
  }

  if (sessionId !== undefined && request.method === "DELETE") {
    await services.mcp?.closeSession(sessionId)
    await run(services.db.deleteSession(sessionId))
    await appendAndPublish(services.db, fanout, "session.deleted", sessionId, { id: sessionId })
    writeJson(response, 204, undefined)
    return true
  }

  if (await routeSessionActions(services, fanout, routeState, request, response, url, config)) {
    return true
  }

  return false
}

const createServerSession = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  payload: CreateSessionRequest,
  project: Project
): Promise<SessionSummary> => {
  const cwd = await resolveSessionCwdOrFail(services, serverId, project, payload.worktreeName)
  const accountContext =
    payload.harnessAccountId === undefined
      ? await services.auth?.activeAccountContext(payload.harnessId)
      : await services.auth?.accountContext(payload.harnessAccountId)
  /* v8 ignore next -- both accepted and rejected auth-gating paths are integration-tested. */
  if (
    services.auth !== undefined &&
    accountContext === undefined &&
    payload.deferAgentSession !== true
  ) {
    throw new HttpFailure(409, "Select a signed-in harness account before creating a session")
  }
  const harnessAccountId = payload.harnessAccountId ?? accountContext?.id
  // The session id is generated up front so the standing event sink can bind
  // to it before the agent session exists.
  const sessionId = payload.id ?? randomUUID()
  const sink = sessionEventSink(services, fanout, serverId, sessionId)
  const toolGateway = await services.mcp?.issueGateway(sessionId, project.id, sink)
  const agentSessionId =
    payload.deferAgentSession === true
      ? ""
      : (payload.agentSessionId ??
        (await run(
          services.agents.createAgentSession(
            payload.harnessId,
            cwd,
            sink,
            accountContext,
            toolGateway
          )
        )))
  return run(
    services.db.createSession({
      ...payload,
      id: sessionId,
      // Use the resolved project's canonical id (the client may have sent a
      // different-cased UUID) so the session's foreign key matches the row.
      projectId: project.id,
      ...(harnessAccountId === undefined ? {} : { harnessAccountId }),
      agentSessionId
    })
  )
}

/// Create-or-return for sessions: the existing-row and in-flight-create
/// checks (concurrent POSTs for the same client-supplied id must not spawn
/// two agent sessions) shared by POST /v1/sessions and the combined
/// /open route.
const createSessionIfMissing = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  payload: CreateSessionRequest
): Promise<{ readonly session: SessionSummary; readonly created: boolean }> => {
  if (payload.id !== undefined) {
    const existing = await findSession(services.db, payload.id)
    if (existing !== undefined) {
      return { session: existing, created: false }
    }
    const pending = routeState.pendingSessionCreates.get(payload.id)
    if (pending !== undefined) {
      return { session: await pending, created: false }
    }
  }
  const project = await getProjectOrFail(services.db, payload.projectId)
  const create = createServerSession(services, fanout, config.id, payload, project)
  if (payload.id !== undefined) {
    routeState.pendingSessionCreates.set(payload.id, create)
  }
  const session = await create.finally(() => {
    if (payload.id !== undefined) {
      routeState.pendingSessionCreates.delete(payload.id)
    }
  })
  await appendAndPublish(services.db, fanout, "session.created", session.id, session)
  return { session, created: true }
}

/// The full PATCH side-effect set — archive teardown and the
/// updated/archived event fanout — shared by PATCH /v1/sessions/:id and the
/// combined /open route so opening a chat behaves exactly like the discrete
/// update it replaced.
const applySessionUpdate = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  sessionId: string,
  payload: UpdateSessionRequest
): Promise<SessionSummary> => {
  const session = await run(services.db.updateSession(sessionId, payload))
  if (session.isArchived) {
    await archiveSessionRuntime(services, session)
    await removeArchivedSessionWorktree(services, config.id, session)
  }
  await appendAndPublish(
    services.db,
    fanout,
    session.isArchived ? "session.archived" : "session.updated",
    session.id,
    session
  )
  return session
}

/// The standing per-session sink: every runtime event — in-turn or
/// agent-initiated — is persisted and fanned out here. User echoes are
/// filtered because the server materializes its own copy when a prompt is
/// accepted.
const sessionEventSink =
  (
    services: CodevisorServerServices,
    fanout: EventFanout,
    serverId: string,
    sessionId: string
  ): RuntimeEventSink =>
  (event) => {
    if (isUserRuntimeEvent(event)) {
      return
    }
    if (event.kind === "session.authRequired") {
      return (async () => {
        const session = await run(services.db.getSessionSummary(sessionId))
        const detail =
          isRecord(event.payload) && typeof event.payload.detail === "string"
            ? event.payload.detail
            : undefined
        /* v8 ignore next -- sessions with and without pinned accounts are integration-tested. */
        if (session?.harnessAccountId !== undefined) {
          await services.auth?.markAccountExpired(session.harnessAccountId, detail)
        }
        await materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
      })()
    }
    return materializeRuntimeEvent(services.db, fanout, serverId, event, sessionId)
  }

/// Derives the directory a session runs in: the project's folder on this
/// server, or its worktree at ~/codevisor/{projectId}/{worktreeName}. The result
/// must stay deterministic per session so the agent-runtime session cache hits.
const resolveSessionCwdOrFail = async (
  services: CodevisorServerServices,
  serverId: string,
  project: Project,
  worktreeName: string | undefined
): Promise<string> => {
  const location = localLocationOrFail(serverId, project)
  if (worktreeName === undefined) {
    assertLocationFolderExists(location)
    return location.folderPath
  }
  const worktree = (await run(services.db.listWorktrees(project.id))).find(
    (candidate) => candidate.name === worktreeName && candidate.serverId === serverId
  )
  if (worktree === undefined) {
    throw new HttpFailure(400, `Worktree not found for project ${project.id}: ${worktreeName}`)
  }
  if (existingDirectory(worktree.path) === undefined) {
    throw new HttpFailure(400, `Worktree folder does not exist: ${worktree.path}`)
  }
  return worktree.path
}

/// Archiving retires the session's runtime: the agent process shuts down and
/// every background-task terminal it registered is killed and removed — a
/// dev server must not keep running under an archived chat. Best-effort: the
/// archive itself must succeed even if the runtime is already gone.
const archiveSessionRuntime = async (
  services: CodevisorServerServices,
  session: SessionSummary
): Promise<void> => {
  await services.mcp?.closeSession(session.id)
  /* v8 ignore next -- SessionSummary types agentSessionId as optional, but created sessions always carry one. */
  const agentSessionId = session.agentSessionId ?? ""
  if (agentSessionId.length === 0) {
    return
  }
  try {
    await run(services.agents.closeAgentSession(agentSessionId))
    await run(services.terminal.closeTerminalsForSessionPrefix(`${agentSessionId}:bg:`))
    /* v8 ignore next 3 -- best-effort: archiving must succeed even when the runtime is already gone. */
  } catch {
    // Best-effort.
  }
}

/// Deletes an archived session's git worktree from disk once no other active
/// session on this server still relies on that worktree: it detaches the git
/// registration, removes the working directory, and drops the tracking row.
/// The just-archived session is already flagged archived here, so it never
/// counts itself as an active user.
const removeArchivedSessionWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  session: SessionSummary
): Promise<void> => {
  const worktreeName = session.worktreeName
  if (worktreeName === undefined) {
    return
  }
  const stillInUse = (await run(services.db.listSessions)).some(
    (candidate) =>
      !candidate.isArchived &&
      candidate.projectId === session.projectId &&
      candidate.worktreeName === worktreeName
  )
  if (stillInUse) {
    return
  }
  const worktree = (await run(services.db.listWorktrees(session.projectId))).find(
    (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
  )
  if (worktree === undefined) {
    return
  }
  const project = await getProjectOrFail(services.db, session.projectId)
  const location = localLocationOrFail(serverId, project)
  await removeWorktree(location.folderPath, worktree.path)
  await run(services.db.deleteWorktree(worktree.id))
}

const findSession = async (
  db: CodevisorDatabaseService,
  id: string
): Promise<SessionSummary | undefined> => {
  try {
    return await run(db.getSessionSummary(id))
  } catch {
    return undefined
  }
}

const routeSessionActions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL,
  config: CodevisorServerConfig
): Promise<boolean> => {
  const connectSessionId = matchRoute(url.pathname, "/v1/sessions/:id/connect")
  if (connectSessionId !== undefined && request.method === "POST") {
    const metadata = await ensureAgentSessionFor(services, fanout, config.id, connectSessionId)
    writeJson(response, 200, metadata)
    return true
  }

  // One-round-trip chat open: ensure the project and session records exist
  // and return the first transcript page together, replacing the client's
  // listProjects → createProject → listSessions → create/update → transcript
  // waterfall. Deliberately does NOT touch the agent runtime — clients call
  // /connect in parallel so the transcript can paint while the agent process
  // is still spawning. Older clients keep using the discrete routes; newer
  // clients fall back to them when this route 404s on an older server.
  const openSessionId = matchRoute(url.pathname, "/v1/sessions/:id/open")
  if (openSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, OpenSessionRequestSchema)
    if (
      payload.session.id !== undefined &&
      payload.session.id.toLowerCase() !== openSessionId.toLowerCase()
    ) {
      throw new HttpFailure(400, "Session id in body does not match the path")
    }
    const limit = payload.transcriptLimit ?? 32
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpFailure(400, "Invalid transcript page limit")
    }
    // Project: create-if-missing. An existing record is never updated from
    // the open snapshot — it may predate changes made elsewhere (archiving),
    // and opening a chat must not revert them.
    if (payload.project?.id !== undefined) {
      const wanted = payload.project.id.toLowerCase()
      const exists = (await run(services.db.listProjects)).some(
        (candidate) => candidate.id.toLowerCase() === wanted
      )
      if (!exists) {
        const project = await run(services.db.createProject(payload.project))
        await appendAndPublish(services.db, fanout, "project.created", project.id, project)
      }
    }
    const existing = await findSession(services.db, openSessionId)
    const session =
      existing === undefined
        ? (
            await createSessionIfMissing(services, fanout, routeState, config, {
              ...payload.session,
              id: openSessionId
            })
          ).session
        : payload.update === undefined
          ? existing
          : await applySessionUpdate(services, fanout, config, openSessionId, payload.update)
    const transcript = await run(services.db.getTranscriptPage(openSessionId, undefined, limit))
    writeJson(response, 200, { session, transcript })
    return true
  }

  const transcriptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/transcript")
  if (transcriptSessionId !== undefined && request.method === "GET") {
    const rawBefore = url.searchParams.get("before")
    const before = rawBefore === null ? undefined : Number(rawBefore)
    if (before !== undefined && (!Number.isSafeInteger(before) || before < 0)) {
      throw new HttpFailure(400, "Invalid transcript cursor")
    }
    const rawLimit = url.searchParams.get("limit")
    const limit = rawLimit === null ? 32 : Number(rawLimit)
    if (!Number.isSafeInteger(limit) || limit < 1) {
      throw new HttpFailure(400, "Invalid transcript page limit")
    }
    writeJson(
      response,
      200,
      await run(services.db.getTranscriptPage(transcriptSessionId, before, limit))
    )
    return true
  }

  const transcriptDetails = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/transcript/:itemId/details"
  )
  if (transcriptDetails !== undefined && request.method === "GET") {
    const { id, itemId } = transcriptDetails as { readonly id: string; readonly itemId: string }
    const details = await run(services.db.getTranscriptItemDetails(id, itemId))
    if (details === undefined) {
      throw new HttpFailure(404, `Transcript item not found: ${itemId}`)
    }
    writeJson(response, 200, details)
    return true
  }

  const queueSessionId = matchRoute(url.pathname, "/v1/sessions/:id/queue")
  if (queueSessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, await run(services.db.listPromptQueue(queueSessionId)))
    return true
  }

  // Full persisted event history for one session — the client replays these
  // through its live pipeline to rebuild rich transcripts (tool calls, diffs)
  // that the text-only conversation snapshot cannot carry.
  const eventsSessionId = matchRoute(url.pathname, "/v1/sessions/:id/events")
  if (eventsSessionId !== undefined && request.method === "GET") {
    writeJson(
      response,
      200,
      await sessionHistoryEventsWithSetup(services.db, config.id, eventsSessionId)
    )
    return true
  }

  const queueItemRoute = matchRouteParams(url.pathname, "/v1/sessions/:id/queue/:queueId")
  if (queueItemRoute !== undefined && request.method === "PATCH") {
    const { id, queueId } = queueItemRoute as { readonly id: string; readonly queueId: string }
    const payload = await readSchema(request, UpdateQueuedPromptRequest)
    const item = await run(services.db.updatePromptQueueItem(id, queueId, payload.text))
    await publishPromptQueue(services.db, fanout, id)
    writeJson(response, 200, item)
    return true
  }

  if (queueItemRoute !== undefined && request.method === "DELETE") {
    const { id, queueId } = queueItemRoute as { readonly id: string; readonly queueId: string }
    await run(services.db.deletePromptQueueItem(id, queueId))
    await publishPromptQueue(services.db, fanout, id)
    writeNoContent(response)
    return true
  }

  const promptSessionId = matchRoute(url.pathname, "/v1/sessions/:id/prompt")
  if (promptSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, PromptRequest)
    const actionKey = actionIdKey(promptSessionId, payload.clientActionId)
    if (payload.clientActionId !== undefined) {
      const existing = await run(
        services.db.getSessionActionResult(promptSessionId, payload.clientActionId)
      )
      if (existing !== undefined) {
        writeJson(response, 202, existing)
        return true
      }
    }
    /* v8 ignore next 4 -- duplicate in-flight requests normally hit the saved idempotency row above. */
    if (actionKey !== undefined && routeState.pendingPromptActions.has(actionKey)) {
      writeJson(response, 202, { accepted: true, sessionId: promptSessionId })
      return true
    }
    const attachments = payload.attachments ?? []
    if (attachments.length > MAX_PROMPT_ATTACHMENTS) {
      throw new HttpFailure(422, `A prompt may carry at most ${MAX_PROMPT_ATTACHMENTS} attachments`)
    }
    // Fail unknown file ids at send time rather than mid-drain.
    for (const attachment of attachments) {
      if ((await run(services.db.getFileMetadata(attachment.fileId))) === undefined) {
        throw new HttpFailure(422, `Unknown attachment file: ${attachment.fileId}`)
      }
    }
    if (actionKey !== undefined) {
      routeState.pendingPromptActions.add(actionKey)
    }
    const queueItem = await run(
      services.db.createPromptQueueItem(
        promptSessionId,
        payload.text,
        attachments,
        payload.messageId
      )
    )
    const result: PromptAcceptedResponse = {
      accepted: true,
      sessionId: promptSessionId,
      queueItemId: queueItem.id
    }
    if (payload.clientActionId !== undefined) {
      await run(
        services.db.saveSessionActionResult(
          promptSessionId,
          payload.clientActionId,
          "prompt",
          result
        )
      )
    }
    writeJson(response, 202, result)
    void drainPromptQueue(services, fanout, routeState, config.id, promptSessionId).finally(() => {
      if (actionKey !== undefined) {
        routeState.pendingPromptActions.delete(actionKey)
      }
    })
    return true
  }

  const cancelSessionId = matchRoute(url.pathname, "/v1/sessions/:id/cancel")
  if (cancelSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, CancelRequest)
    await writeIdempotentAction(
      services,
      response,
      cancelSessionId,
      "cancel",
      payload,
      async () => {
        const agentSession = await ensureAgentSessionFor(
          services,
          fanout,
          config.id,
          cancelSessionId
        )
        await run(services.agents.cancel(agentSession.sessionId))
        return { cancelled: true }
      }
    )
    return true
  }

  const modeSessionId = matchRoute(url.pathname, "/v1/sessions/:id/mode")
  if (modeSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetModeRequest)
    await writeIdempotentAction(services, response, modeSessionId, "mode", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, modeSessionId)
      await run(services.agents.setMode(agentSession.sessionId, payload.modeId))
      return { modeId: payload.modeId }
    })
    return true
  }

  const configSessionId = matchRoute(url.pathname, "/v1/sessions/:id/config")
  if (configSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetConfigRequest)
    await writeIdempotentAction(
      services,
      response,
      configSessionId,
      "config",
      payload,
      async () => {
        const agentSession = await ensureAgentSessionFor(
          services,
          fanout,
          config.id,
          configSessionId
        )
        const configOptions = await run(
          services.agents.setConfigOption(agentSession.sessionId, payload.configId, payload.value)
        )
        await run(
          services.db.replaceSessionConfigSelections(
            configSessionId,
            configSelectionsFromOptions(configOptions)
          )
        )
        return { configId: payload.configId }
      }
    )
    return true
  }

  const goalSessionId = matchRoute(url.pathname, "/v1/sessions/:id/goal")
  if (goalSessionId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, SetGoalRequest)
    await writeIdempotentAction(services, response, goalSessionId, "goal", payload, async () => {
      const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
      // Double-option passthrough: only forward the tokenBudget key when the
      // client sent one (absent = keep, null = clear, number = set).
      return await run(
        services.agents.setGoal(agentSession.sessionId, {
          ...(payload.objective === undefined ? {} : { objective: payload.objective }),
          ...(payload.status === undefined ? {} : { status: payload.status }),
          ...("tokenBudget" in payload ? { tokenBudget: payload.tokenBudget ?? null } : {})
        })
      )
    })
    return true
  }
  if (goalSessionId !== undefined && request.method === "DELETE") {
    const agentSession = await ensureAgentSessionFor(services, fanout, config.id, goalSessionId)
    await run(services.agents.clearGoal(agentSession.sessionId))
    writeJson(response, 204, undefined)
    return true
  }

  const answerRoute = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/questions/:questionId/answer"
  )
  if (answerRoute !== undefined && request.method === "POST") {
    const answerSessionId = answerRoute.id as string
    const questionId = answerRoute.questionId as string
    const payload = await readSchema(request, SetQuestionAnswerRequest)
    await writeIdempotentAction(
      services,
      response,
      answerSessionId,
      "question-answer",
      payload,
      async () => {
        const answer = {
          outcome: payload.outcome,
          ...(payload.answers === undefined ? {} : { answers: payload.answers })
        }
        const handledByAutomation =
          (await services.mcp?.answerQuestion(answerSessionId, questionId, answer)) ?? false
        if (!handledByAutomation) {
          const agentSession = await ensureAgentSessionFor(
            services,
            fanout,
            config.id,
            answerSessionId
          )
          await run(services.agents.answerQuestion(agentSession.sessionId, questionId, answer))
        }
        return { outcome: payload.outcome, questionId }
      }
    )
    return true
  }

  return false
}

const writeIdempotentAction = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  sessionId: string,
  actionKind: string,
  payload: { readonly clientActionId?: string | undefined },
  runAction: () => Promise<unknown>
): Promise<void> => {
  if (payload.clientActionId !== undefined) {
    const existing = await run(
      services.db.getSessionActionResult(sessionId, payload.clientActionId)
    )
    if (existing !== undefined) {
      writeJson(response, 202, existing)
      return
    }
  }
  const result = await runAction()
  if (payload.clientActionId !== undefined) {
    await run(
      services.db.saveSessionActionResult(sessionId, payload.clientActionId, actionKind, result)
    )
  }
  writeJson(response, 202, result)
}

const actionIdKey = (sessionId: string, clientActionId: string | undefined): string | undefined =>
  clientActionId === undefined ? undefined : `${sessionId}:${clientActionId}`

const publishPromptQueue = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  sessionId: string
): Promise<ReadonlyArray<PromptQueueItem>> => {
  const queue = await run(db.listPromptQueue(sessionId))
  await appendAndPublish(db, fanout, "session.queue.updated", sessionId, { queue })
  return queue
}

/// Lifecycle route failures surface as conflicts with the manager's reason.
const conflictFrom = (cause: unknown): HttpFailure =>
  new HttpFailure(409, cause instanceof Error ? cause.message : String(cause))

/* v8 ignore next 3 -- defensive: shared swallow for fire-and-forget event/drain failures. */
const swallowError = (): undefined => {
  return undefined
}

/// The session's harness id + display name when its harness update gate is
/// closed; undefined when dispatch may proceed. Failures resolve open — a
/// lookup error must never wedge prompt dispatch.
const sessionUpdateGate = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<{ readonly harnessId: string; readonly harnessName: string } | undefined> => {
  const lifecycle = services.lifecycle
  if (lifecycle === undefined) return undefined
  const session = await run(services.db.getSessionSummary(sessionId)).catch(swallowError)
  if (session === undefined || !lifecycle.isGated(session.harnessId)) return undefined
  const catalogName = services.agents.catalog.find(
    (definition) => definition.id === session.harnessId
  )?.name
  /* v8 ignore next -- defensive: sessions on uncataloged harnesses fall back to the id. */
  return { harnessId: session.harnessId, harnessName: catalogName ?? session.harnessId }
}

const drainPromptQueue = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string,
  sessionId: string
): Promise<void> => {
  if (routeState.activePromptSessions.has(sessionId)) {
    // This item really is waiting behind an in-flight prompt, so expose it to
    // clients as queued. The first prompt takes the owner path below and is
    // claimed before any queue snapshot is published; otherwise every normal
    // send briefly flashes as a one-item queue before execution starts.
    await publishPromptQueue(services.db, fanout, sessionId)
    return
  }
  // Harness-update gate: the prompt is already durable in prompt_queue_items
  // and the client has its 202 — holding is simply not claiming. The gate
  // release listener re-drains every held session.
  const gate = await sessionUpdateGate(services, sessionId)
  if (gate !== undefined) {
    const firstHold = !routeState.gatedSessions.has(sessionId)
    routeState.gatedSessions.set(sessionId, gate.harnessId)
    await publishPromptQueue(services.db, fanout, sessionId)
    if (firstHold) {
      await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
        harnessId: gate.harnessId,
        harnessName: gate.harnessName,
        state: "waiting"
      }).catch(swallowError)
    }
    return
  }
  routeState.activePromptSessions.add(sessionId)
  // Turn accounting for update-when-idle: the lifecycle manager runs armed
  // updates when a harness's last in-flight turn ends.
  const busyHarnessId = await run(services.db.getSessionSummary(sessionId))
    .then((session) => session.harnessId)
    .catch(swallowError)
  /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
  if (busyHarnessId !== undefined) services.lifecycle?.notifyTurnStarted(busyHarnessId)
  try {
    while (true) {
      // A gate that closed mid-drain (Update Now) holds the *next* item —
      // registering the session so the release re-drains what remains.
      /* v8 ignore start -- timing-dependent: requires the gate to close between
         two queue claims. The hold/release semantics are covered by the
         pre-drain gate path and the lifecycle manager's gating tests. */
      if (
        services.lifecycle !== undefined &&
        busyHarnessId !== undefined &&
        services.lifecycle.isGated(busyHarnessId)
      ) {
        const firstHold = !routeState.gatedSessions.has(sessionId)
        routeState.gatedSessions.set(sessionId, busyHarnessId)
        if (firstHold) {
          const harnessName =
            services.agents.catalog.find((definition) => definition.id === busyHarnessId)?.name ??
            busyHarnessId
          await appendAndPublish(services.db, fanout, "session.updateGate.updated", sessionId, {
            harnessId: busyHarnessId,
            harnessName,
            state: "waiting"
          }).catch(() => undefined)
        }
        return
      }
      /* v8 ignore stop */
      const item = await run(services.db.claimPromptQueueItem(sessionId))
      if (item === undefined) {
        await publishPromptQueue(services.db, fanout, sessionId)
        return
      }
      await publishPromptQueue(services.db, fanout, sessionId)
      await runPromptInBackground(
        services,
        fanout,
        serverId,
        sessionId,
        item.id,
        item.text,
        item.attachments
      )
      await run(services.db.completePromptQueueItem(sessionId, item.id))
    }
  } finally {
    routeState.activePromptSessions.delete(sessionId)
    /* v8 ignore next -- defensive: unknown sessions simply skip turn accounting. */
    if (busyHarnessId !== undefined) services.lifecycle?.notifyTurnEnded(busyHarnessId)
  }
}

const runPromptInBackground = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  queueItemId: string,
  text: string,
  attachments?: ReadonlyArray<AttachmentRef>
): Promise<void> => {
  try {
    const refs = attachments ?? []
    await materializeRuntimeEvent(
      services.db,
      fanout,
      serverId,
      {
        kind: "session.output",
        subjectId: sessionId,
        payload: {
          role: "user",
          messageId: queueItemId,
          text,
          ...(refs.length === 0 ? {} : { attachments: refs })
        }
      },
      sessionId
    )
    const agentSession = await ensureAgentSessionFor(services, fanout, serverId, sessionId)
    // Session output, turn lifecycle, and the final stopReason all flow
    // through the standing sink registered at session create/load time.
    const input =
      refs.length === 0
        ? text
        : { attachments: await resolvePromptAttachments(services, refs), text }
    await run(services.agents.prompt(agentSession.sessionId, input))
  } catch (cause) {
    if (isAuthenticationFailure(cause)) {
      const session = await run(services.db.getSessionSummary(sessionId))
      /* v8 ignore next -- auth failures on pinned and legacy sessions are integration-tested. */
      if (session.harnessAccountId !== undefined) {
        await services.auth?.markAccountExpired(session.harnessAccountId, failureMessage(cause))
      }
      await appendAndPublish(services.db, fanout, "session.authRequired", sessionId, {
        detail: failureMessage(cause),
        serverId
      })
    }
    await appendAndPublish(services.db, fanout, "session.error", sessionId, {
      message: failureMessage(cause),
      serverId
    })
  }
}

const sessionHistoryEventsWithSetup = async (
  db: CodevisorDatabaseService,
  serverId: string,
  sessionId: string
): Promise<ReadonlyArray<EventEnvelope>> => {
  const sessionEvents = await run(db.listSubjectEvents(sessionId))
  if (sessionEvents.some((event) => event.kind === "worktree.setup")) {
    return sessionEvents
  }
  const session = await run(db.getSessionSummary(sessionId))
  const worktreeName = session.worktreeName
  if (worktreeName === undefined) {
    return sessionEvents
  }
  const worktree = (await run(db.listWorktrees(session.projectId))).find(
    (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
  )
  if (worktree === undefined) {
    return sessionEvents
  }
  const setupEvents = await run(db.listSubjectEvents(worktree.id))
  return [...sessionEvents, ...setupEvents].sort((left, right) => left.id - right.id)
}

const routeFiles = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "POST" && url.pathname === "/v1/files") {
    const store = services.attachments
    const object = await store.putStream(request)
    const name = sanitizeFileName(url.searchParams.get("name") ?? "attachment")
    const mimeType =
      request.headers["content-type"]?.split(";")[0]?.trim() ?? "application/octet-stream"
    const metadata: FileMetadata = {
      id: randomUUID(),
      name,
      mimeType,
      sizeBytes: object.sizeBytes,
      sha256: object.sha256,
      kind: sniffAttachmentKind(object.header, mimeType),
      createdAt: new Date().toISOString()
    }
    await run(services.db.createDiskFile(metadata))
    writeJson(response, 201, metadata)
    return true
  }

  const fileId = matchRoute(url.pathname, "/v1/files/:id")
  if (fileId !== undefined && request.method === "GET") {
    const file = await readAttachment(services, fileId)
    response.writeHead(200, {
      // Files are immutable (content is stored once at upload), so clients
      // may cache aggressively.
      "Cache-Control": "private, max-age=31536000, immutable",
      "Content-Disposition": `inline; filename*=UTF-8''${encodeURIComponent(file.metadata.name)}`,
      "Content-Length": file.data.byteLength,
      "Content-Type": file.metadata.mimeType
    })
    response.end(file.data)
    return true
  }

  return false
}

const routeTerminals = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method === "POST" && url.pathname === "/v1/terminals") {
    writeJson(
      response,
      201,
      await run(services.terminal.createTerminal(await readSchema(request, TerminalCreateRequest)))
    )
    return true
  }

  // Kills the session's live shell so the next createTerminal starts fresh
  // (used by the clients' "Restart Terminal" action).
  const terminalSessionId = matchRoute(url.pathname, "/v1/terminals/session/:sessionId")
  if (terminalSessionId !== undefined && request.method === "DELETE") {
    const closed = await run(services.terminal.closeTerminalForSession(terminalSessionId))
    writeJson(response, closed ? 200 : 404, { closed })
    return true
  }

  return false
}

const handleEvents = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  url: URL,
  response: ServerResponse
): Promise<void> => {
  const since = Number(url.searchParams.get("since") ?? "0")
  response.writeHead(200, {
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Content-Type": "text/event-stream"
  })
  for (const event of await run(db.listEvents(Number.isFinite(since) ? since : 0))) {
    writeSse(response, event)
  }
  const unsubscribe = fanout.subscribe((event) => {
    if (isGlobalShellEnvelope(event)) writeSse(response, event)
  })
  response.on("close", unsubscribe)
}

const isGlobalShellEnvelope = (event: EventEnvelope): boolean =>
  event.subjectRevision === undefined || event.globalEventId !== undefined

const handleUpgrade = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  socket: Socket,
  head: Buffer,
  webSocketServer: WebSocketServer
): Promise<void> => {
  try {
    const url = parseRequestUrl(request)
    if (
      request.method === "GET" &&
      url.pathname === "/v1/browser-use/extension/socket" &&
      services.mcp !== undefined &&
      isLocalhost(request.socket.remoteAddress) &&
      request.headers.origin === `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}`
    ) {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        services.mcp!.acceptBrowserExtension(webSocket)
      })
      return
    }
    await authorize(services.db, config, request)
    if (request.method === "GET" && url.pathname === "/v1/events/socket") {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        void attachEventSocket(services.db, fanout, numberSearchParam(url, "since"), webSocket)
      })
      return
    }

    const sessionEventId = matchRoute(url.pathname, "/v1/sessions/:id/events/socket")
    if (request.method === "GET" && sessionEventId !== undefined) {
      webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
        void attachEventSocket(
          services.db,
          fanout,
          numberSearchParam(url, "since"),
          webSocket,
          sessionEventId
        )
      })
      return
    }

    const terminalId = matchRoute(url.pathname, "/v1/terminals/:id/socket")
    if (terminalId === undefined) {
      socket.destroy()
      return
    }

    webSocketServer.handleUpgrade(request, socket, head, (webSocket) => {
      void attachTerminalSocket(
        services.terminal,
        terminalId,
        numberSearchParam(url, "lastOutputSeq"),
        webSocket
      )
    })
  } catch {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n")
    socket.destroy()
  }
}

const attachEventSocket = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  since: number,
  webSocket: WebSocket,
  subjectId?: string
): Promise<void> => {
  const liveOnly = since >= Number.MAX_SAFE_INTEGER
  let cursor = liveOnly ? 0 : since
  let isReplaying = true
  const liveQueue: Array<EventEnvelope> = []
  const sendEvent = (event: EventEnvelope): void => {
    if (subjectId !== undefined && event.subjectId !== subjectId) {
      return
    }
    // Session-only runtime traffic never enters the global shell log and must
    // not wake every project-list subscriber.
    if (subjectId === undefined && !isGlobalShellEnvelope(event)) {
      return
    }
    const scopedId =
      subjectId === undefined ? (event.globalEventId ?? event.id) : event.subjectRevision
    if (scopedId === undefined || scopedId <= cursor) return
    cursor = scopedId
    if (webSocket.readyState === WebSocket.OPEN) {
      webSocket.send(JSON.stringify(subjectId === undefined ? event : { ...event, id: scopedId }))
    }
  }
  const unsubscribe = fanout.subscribe((event) => {
    if (isReplaying) {
      liveQueue.push(event)
      return
    }
    sendEvent(event)
  })
  webSocket.on("close", unsubscribe)
  try {
    if (!liveOnly) {
      const replay =
        subjectId === undefined
          ? await run(db.listEvents(since))
          : await run(db.listSubjectEvents(subjectId, since))
      for (const event of replay) sendEvent(event)
    }
    isReplaying = false
    for (const event of liveQueue) {
      sendEvent(event)
    }
  } catch {
    /* v8 ignore next -- defensive close path for database failures during websocket replay. */
    unsubscribe()
    /* v8 ignore next -- defensive close path for database failures during websocket replay. */
    webSocket.close()
  }
}

const attachTerminalSocket = async (
  terminal: TerminalManagerService,
  terminalId: string,
  lastOutputSeq: number,
  webSocket: WebSocket
): Promise<void> => {
  try {
    const disconnect = await run(
      terminal.connectTerminal(terminalId, lastOutputSeq, (frame) => {
        /* v8 ignore next -- the close event removes this sink before normal closed-socket output. */
        if (webSocket.readyState === WebSocket.OPEN) {
          webSocket.send(JSON.stringify(frame))
        }
      })
    )
    webSocket.on("message", (data) => {
      const frame = parseTerminalFrameOrSend(data.toString(), webSocket)
      if (frame === undefined) {
        return
      }
      void run(terminal.handleClientFrame(terminalId, frame)).catch((cause: unknown) => {
        webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
      })
    })
    webSocket.on("close", disconnect)
  } catch (cause) {
    webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
    webSocket.close()
  }
}

/// Echoes Access-Control-Allow-Origin for requests from an allowlisted
/// browser origin (never a wildcard — see CodevisorServerConfig.corsOrigins).
const applyCorsHeaders = (
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse
): void => {
  const origin = request.headers.origin
  if (origin === undefined || config.corsOrigins === undefined) {
    return
  }
  if (config.corsOrigins.includes(origin)) {
    response.setHeader("Access-Control-Allow-Origin", origin)
    response.setHeader("Vary", "Origin")
  }
}

const authorize = async (
  db: CodevisorDatabaseService,
  config: CodevisorServerConfig,
  request: IncomingMessage
): Promise<void> => {
  if (!config.auth.requireBearerToken) {
    return
  }
  if (config.auth.allowLocalhostWithoutAuth && isLocalhost(request.socket.remoteAddress)) {
    return
  }
  const token = parseBearerToken(request.headers.authorization)
  if (token !== undefined && (await run(db.verifyBearerToken(token)))) {
    return
  }
  throw new HttpFailure(401, "Unauthorized")
}

const discoverHarnesses = async (
  services: CodevisorServerServices,
  forceAuth = false,
  harnessId?: string,
  /// Lifecycle decoration (update knowledge, install methods) rides only on
  /// requests that render it — Settings, rescans, update checks. The plain
  /// list stays as light as possible for the composer's harness picker.
  includeLifecycle = false
): Promise<ReadonlyArray<Harness>> => {
  const discovered = await run(
    services.db.applyHarnessSettings(await run(services.agents.discoverHarnesses))
  )
  const filtered =
    harnessId === undefined ? discovered : discovered.filter((harness) => harness.id === harnessId)
  const harnesses =
    includeLifecycle && services.lifecycle !== undefined
      ? await services.lifecycle.decorateHarnesses(filtered)
      : filtered
  return services.auth === undefined
    ? harnesses
    : services.auth.decorateHarnesses(harnesses, forceAuth)
}

const getProjectOrFail = async (
  db: CodevisorDatabaseService,
  projectId: string
): Promise<Project> => {
  // Case-insensitive: UUIDs are case-insensitive identifiers, but clients can
  // send either case (Swift uppercases, Node lowercases). A mismatch here used
  // to read as a spurious "project not found".
  const wanted = projectId.toLowerCase()
  const project = (await run(db.listProjects)).find(
    (candidate) => candidate.id.toLowerCase() === wanted
  )
  if (project === undefined) {
    throw new HttpFailure(404, `Project not found: ${projectId}`)
  }
  return project
}

const localLocationOrFail = (serverId: string, project: Project): ProjectLocation => {
  const location = project.locations.find((candidate) => candidate.serverId === serverId)
  if (location === undefined) {
    throw new HttpFailure(400, `Project has no folder on this machine: ${project.id}`)
  }
  return location
}

const ensureAgentSessionFor = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<AgentSessionMetadata> => {
  const session = await run(services.db.getSessionSummary(sessionId))
  const project = await getProjectOrFail(services.db, session.projectId)
  const cwd = await resolveSessionCwdOrFail(services, serverId, project, session.worktreeName)
  const accountContext =
    session.harnessAccountId === undefined
      ? await services.auth?.activeAccountContext(session.harnessId)
      : await services.auth?.accountContext(session.harnessAccountId)
  /* v8 ignore next -- authenticated and blocked session-resume paths are integration-tested. */
  if (services.auth !== undefined && accountContext === undefined) {
    throw new HttpFailure(409, "Select a signed-in harness account before continuing this session")
  }
  if (session.harnessAccountId === undefined && accountContext !== undefined) {
    await run(services.db.bindSessionHarnessAccount(session.id, accountContext.id))
  }
  if (session.agentSessionId === "") {
    const sink = sessionEventSink(services, fanout, serverId, sessionId)
    const toolGateway = await services.mcp?.issueGateway(session.id, session.projectId, sink)
    const agentSessionId = await run(
      services.agents.createAgentSession(session.harnessId, cwd, sink, accountContext, toolGateway)
    )
    const updatedSession = await run(services.db.updateSession(sessionId, { agentSessionId }))
    await appendAndPublish(
      services.db,
      fanout,
      "session.updated",
      updatedSession.id,
      updatedSession
    )
    const metadata = await run(
      services.agents.loadAgentSession(
        session.harnessId,
        agentSessionId,
        cwd,
        sink,
        accountContext,
        toolGateway
      )
    )
    return restoreSessionConfigSelections(services, sessionId, metadata)
  }
  const agentSessionId = session.agentSessionId ?? sessionId
  const sink = sessionEventSink(services, fanout, serverId, sessionId)
  const toolGateway = await services.mcp?.issueGateway(session.id, session.projectId, sink)
  const metadata = await run(
    services.agents.loadAgentSession(
      session.harnessId,
      agentSessionId,
      cwd,
      sink,
      accountContext,
      toolGateway
    )
  )
  return restoreSessionConfigSelections(services, sessionId, metadata)
}

const selectableValues = (option: SessionConfigOption): ReadonlySet<string> =>
  new Set(
    option.options.flatMap((entry) =>
      "value" in entry ? [entry.value] : entry.options.map((nested) => nested.value)
    )
  )

const configSelectionsFromOptions = (
  options: ReadonlyArray<SessionConfigOption>
): Readonly<Record<string, string>> =>
  Object.fromEntries(options.map((option) => [option.id, option.currentValue]))

const configRestorePriority = (option: SessionConfigOption | undefined): number => {
  if (option?.category === "model" || option?.id === "model") return 0
  if (option?.category === "thought_level") return 1
  if (option?.category === "speed" || option?.id === "speed") return 2
  return 3
}

/// Rehydrates durable per-chat picker values after the provider has resumed
/// its native thread. Model goes first because it can replace the available
/// reasoning and speed lists. Every later value is validated against the
/// latest options returned by the provider; removed values fall through to
/// the provider's current default and the resolved snapshot replaces them.
const restoreSessionConfigSelections = async (
  services: CodevisorServerServices,
  sessionId: string,
  metadata: AgentSessionMetadata
): Promise<AgentSessionMetadata> => {
  const saved = await run(services.db.getSessionConfigSelections(sessionId))
  let configOptions = metadata.configOptions
  const ordered = Object.entries(saved).sort(([leftId], [rightId]) => {
    const left = configOptions.find((option) => option.id === leftId)
    const right = configOptions.find((option) => option.id === rightId)
    const difference = configRestorePriority(left) - configRestorePriority(right)
    return difference === 0 ? leftId.localeCompare(rightId) : difference
  })
  for (const [configId, value] of ordered) {
    const option = configOptions.find((candidate) => candidate.id === configId)
    if (
      option === undefined ||
      option.currentValue === value ||
      !selectableValues(option).has(value)
    ) {
      continue
    }
    try {
      configOptions = await run(
        services.agents.setConfigOption(metadata.sessionId, configId, value)
      )
    } catch {
      // A harness can reject a value between advertising it and applying it.
      // Session open must still succeed; its current value becomes the durable
      // fallback below.
    }
  }
  await run(
    services.db.replaceSessionConfigSelections(
      sessionId,
      configSelectionsFromOptions(configOptions)
    )
  )
  return { ...metadata, configOptions }
}

const existingDirectory = (folderPath: string | null): string | undefined => {
  if (folderPath === null || folderPath.length === 0) {
    return undefined
  }
  try {
    return statSync(folderPath).isDirectory() ? folderPath : undefined
  } catch {
    return undefined
  }
}

const assertLocationFolderExists = (location: ProjectLocation): void => {
  if (existingDirectory(location.folderPath) === undefined) {
    throw new HttpFailure(400, `Project folder does not exist: ${location.folderPath}`)
  }
}

const materializeRuntimeEvent = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  serverId: string,
  event: RuntimeEvent,
  subjectId: string
): Promise<void> => {
  const payload = objectPayload(event.payload)
  const harnessTitle =
    event.kind === "session.updated" &&
    payload.sessionUpdate === "session_info_update" &&
    typeof payload.title === "string"
      ? payload.title.trim()
      : undefined
  if (harnessTitle !== undefined && harnessTitle.length > 0) {
    const updated = await run(db.updateSessionTitleFromHarness(subjectId, harnessTitle))
    if (updated !== undefined) {
      await appendAndPublish(db, fanout, "session.updated", subjectId, updated)
    }
    return
  }
  // appendEvent atomically persists the session event and updates the
  // canonical semantic chat rows. There is deliberately no second legacy
  // conversation write here: a crash can no longer split the two stores.
  await appendAndPublish(db, fanout, event.kind, subjectId, {
    ...payload,
    serverId
  })
}

const appendAndPublish = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  kind: EventEnvelope["kind"],
  subjectId: string,
  payload: unknown
): Promise<EventEnvelope> => {
  const event = await run(db.appendEvent(kind, subjectId, payload))
  await run(fanout.publish(event))
  return event
}

const readSchema = async <S extends Schema.ConstraintDecoder<unknown>>(
  request: IncomingMessage,
  schema: S
): Promise<S["Type"]> => {
  try {
    return decode(schema)(await readJson(request))
  } catch (cause) {
    throw new HttpFailure(400, failureMessage(cause))
  }
}

const readJson = async (request: IncomingMessage): Promise<unknown> => {
  const chunks: Array<Buffer> = []
  for await (const chunk of request) {
    /* v8 ignore next -- Node HTTP request body chunks are Buffers in this server. */
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }
  const raw = Buffer.concat(chunks).toString("utf8")
  if (raw.length === 0) {
    return {}
  }
  try {
    return JSON.parse(raw) as unknown
  } catch {
    throw new HttpFailure(400, "Request body must be valid JSON")
  }
}

const parseTerminalFrame = (raw: string): TerminalClientFrame => {
  try {
    return decode(TerminalClientFrameSchema)(JSON.parse(raw) as unknown)
  } catch (cause) {
    throw new HttpFailure(400, failureMessage(cause))
  }
}

const parseTerminalFrameOrSend = (
  raw: string,
  webSocket: WebSocket
): TerminalClientFrame | undefined => {
  try {
    return parseTerminalFrame(raw)
  } catch (cause) {
    webSocket.send(JSON.stringify({ type: "error", seq: 0, message: failureMessage(cause) }))
    return undefined
  }
}

const numberSearchParam = (url: URL, name: string): number => {
  const parsed = Number(url.searchParams.get(name) ?? "0")
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 0
}

const writeJson = (response: ServerResponse, status: number, body: unknown): void => {
  if (status === 204) {
    response.writeHead(status)
    response.end()
    return
  }
  response.writeHead(status, { "Content-Type": "application/json" })
  response.end(JSON.stringify(body))
}

const writeNoContent = (response: ServerResponse): void => {
  writeJson(response, 204, {})
}

const writeFailure = (response: ServerResponse, cause: unknown): void => {
  /* v8 ignore next -- errors after SSE headers are ended defensively. */
  if (response.headersSent) {
    response.end()
    return
  }
  if (cause instanceof HttpFailure) {
    writeJson(response, cause.status, {
      error: cause.message,
      ...(cause.code === undefined ? {} : { code: cause.code })
    })
    return
  }
  if (cause instanceof AttachmentStoreError) {
    writeJson(response, 500, { error: cause.message })
    return
  }
  if (cause instanceof SkillsError) {
    const status = cause.code === "invalid" ? 400 : cause.code === "notFound" ? 404 : 409
    writeJson(response, status, { code: cause.code, error: cause.message })
    return
  }
  if (cause instanceof NativeMcpError) {
    const status = cause.code === "notFound" ? 404 : cause.code === "conflict" ? 409 : 422
    writeJson(response, status, { code: cause.code, error: cause.message })
    return
  }
  if (cause instanceof CloneError) {
    writeJson(response, 422, {
      error: cause.message,
      /* v8 ignore next -- spawn-level clone failures carry no classification; exercised directly in git.test.ts. */
      ...(cause.code === undefined ? {} : { code: cause.code })
    })
    return
  }
  /* v8 ignore next 3 -- Git command classifications are covered in git.test; this is their thin HTTP mapping. */
  if (cause instanceof GitError) {
    writeJson(response, 422, { error: cause.message })
    return
  }
  writeJson(response, 500, { error: failureMessage(cause) })
}

const writeSse = (response: ServerResponse, event: EventEnvelope): void => {
  response.write(`id: ${event.id}\n`)
  response.write(`event: ${event.kind}\n`)
  response.write(`data: ${JSON.stringify(event)}\n\n`)
}

const parseRequestUrl = (request: IncomingMessage): URL => {
  /* v8 ignore next -- Node HTTP requests always provide url and host in these paths. */
  return new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`)
}

const matchRoute = (pathname: string, pattern: string): string | undefined => {
  const pathParts = pathname.split("/").filter(Boolean)
  const patternParts = pattern.split("/").filter(Boolean)
  if (pathParts.length !== patternParts.length) {
    return undefined
  }
  let captured: string | undefined
  for (let index = 0; index < patternParts.length; index += 1) {
    const patternPart = patternParts[index] as string
    const pathPart = pathParts[index] as string
    if (patternPart.startsWith(":")) {
      captured = decodeURIComponent(pathPart)
    } else if (patternPart !== pathPart) {
      return undefined
    }
  }
  return captured
}

const matchRouteParams = (
  pathname: string,
  pattern: string
): Record<string, string> | undefined => {
  const pathParts = pathname.split("/").filter(Boolean)
  const patternParts = pattern.split("/").filter(Boolean)
  if (pathParts.length !== patternParts.length) {
    return undefined
  }
  const params: Record<string, string> = {}
  for (let index = 0; index < patternParts.length; index += 1) {
    const patternPart = patternParts[index] as string
    const pathPart = pathParts[index] as string
    if (patternPart.startsWith(":")) {
      params[patternPart.slice(1)] = decodeURIComponent(pathPart)
    } else if (patternPart !== pathPart) {
      return undefined
    }
  }
  return params
}

const parseBearerToken = (header: string | undefined): string | undefined => {
  if (header === undefined || !header.startsWith("Bearer ")) {
    return undefined
  }
  return header.slice("Bearer ".length)
}

const localhostAddresses = new Set(["127.0.0.1", "::1", "::ffff:127.0.0.1"])

const isLocalhost = (address: string | undefined): boolean =>
  localhostAddresses.has(String(address))

const conversationRoles = new Set(["user", "assistant", "system"])

const isConversationPayload = (
  payload: unknown
): payload is {
  readonly role: "user" | "assistant" | "system"
  readonly text: string
  readonly messageId?: string
  readonly attachments?: ReadonlyArray<AttachmentRef>
} =>
  typeof payload === "object" &&
  payload !== null &&
  "role" in payload &&
  "text" in payload &&
  conversationRoles.has(String(payload.role)) &&
  typeof payload.text === "string" &&
  (!("messageId" in payload) || typeof payload.messageId === "string") &&
  (!("attachments" in payload) || Array.isArray(payload.attachments))

const conversationPayload = (
  payload: unknown
):
  | {
      readonly role: "user" | "assistant" | "system"
      readonly text: string
      readonly messageId?: string
      readonly attachments?: ReadonlyArray<AttachmentRef>
    }
  | undefined => {
  if (isConversationPayload(payload)) {
    return payload
  }
  if (!isRecord(payload) || typeof payload.sessionUpdate !== "string") {
    return undefined
  }
  // Subagent-attributed chunks stay out of the text conversation snapshot;
  // clients rebuild nested subagent transcripts from the raw event log.
  if (typeof payload.parentToolCallId === "string") {
    return undefined
  }
  const text = textFromRawContent(payload.content)
  if (text === undefined) {
    return undefined
  }
  switch (payload.sessionUpdate) {
    case "user_message_chunk":
      return {
        role: "user",
        text,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
    case "agent_message_chunk":
      return {
        role: "assistant",
        text,
        ...(typeof payload.messageId === "string" ? { messageId: payload.messageId } : {})
      }
    default:
      return undefined
  }
}

const isUserRuntimeEvent = (event: RuntimeEvent): boolean =>
  conversationPayload(event.payload)?.role === "user"

const textFromRawContent = (content: unknown): string | undefined =>
  isRecord(content) && content.type === "text" && typeof content.text === "string"
    ? content.text
    : undefined

const objectPayload = (payload: unknown): Record<string, unknown> =>
  isRecord(payload) ? payload : { value: payload }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

/* v8 ignore next -- route/runtime failures use Error-compatible values. */
const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const isAuthenticationFailure = (cause: unknown): boolean => {
  const message = failureMessage(cause).toLowerCase()
  return (
    message.includes("authentication") ||
    message.includes("unauthorized") ||
    message.includes("not logged in") ||
    message.includes("sign-in") ||
    message.includes("sign in") ||
    message.includes("token expired")
  )
}

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const isAddressInfo = (address: string | AddressInfo | null): address is AddressInfo =>
  typeof address === "object" && address !== null && "port" in address

class HttpFailure extends Error {
  constructor(
    readonly status: number,
    message: string,
    /// Machine-readable failure category, when the client can act on it
    /// (e.g. clone auth_failed → "set up git credentials on the machine").
    readonly code?: string
  ) {
    super(message)
  }
}

const closeServer = (server: Server, app: CodevisorServerApp): Effect.Effect<void, ServerError> =>
  Effect.tryPromise({
    try: () =>
      new Promise<void>((resolve, reject) => {
        void Effect.runPromise(app.close)
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

export { defaultDatabasePath } from "./data-dir.js"
