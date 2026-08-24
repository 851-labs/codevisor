import type { AgentRuntimeService, PromptAttachmentInput } from "@codevisor/agent-runtime"
import { createHash } from "node:crypto"
import type {
  AttachmentRef,
  FileMetadata,
  EventEnvelope,
  Project,
  ProjectLocation,
  ServerKind,
  SessionSummary,
  UpdateInfo,
  Workspace
} from "@codevisor/api"
import { decode, isoTimestamp } from "@codevisor/api"
import {
  AttachmentStoreError,
  worktreePath,
  type AttachmentStore,
  type CodevisorDatabaseService
} from "@codevisor/db"
import { archiveWorktreeFiles, deleteSnapshot, restoreWorktree } from "@codevisor/worktrees"
import { CloneError, GitError, removeWorktree } from "@codevisor/worktrees"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { IncomingMessage, ServerResponse } from "node:http"
import { existsSync, mkdirSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import type { Socket } from "node:net"
import { Context, Effect, Layer, PubSub, Schema } from "effect"
import type { ServerUpdateChannel } from "@codevisor/updater"
import type { SessionActivityController } from "./infra/active-work-sleep-inhibitor.js"
import type { HarnessAuthManager } from "@codevisor/harness-manager"
import type { HarnessLifecycleManager } from "@codevisor/harness-manager"
import type { CustomHarnessStore } from "@codevisor/harness-manager"
import type { McpManager } from "@codevisor/mcp"
import { NativeMcpError, type NativeMcpManager } from "@codevisor/mcp"
import { SkillsError, type SkillsManager } from "@codevisor/skills"
import { PluginsError, type PluginRegistryClient, type PluginsManager } from "@codevisor/plugins"

export class ServerError extends Schema.TaggedErrorClass<ServerError>()("ServerError", {
  operation: Schema.String,
  message: Schema.String
}) {}

export interface CodevisorServerAuthConfig {
  readonly requireBearerToken: boolean
  readonly allowLocalhostWithoutAuth: boolean
}

/// Lets the host process implement self-updating: `check` refreshes and
/// returns the update state (`force` bypasses any host-side cache, `channel`
/// selects the release feed), `apply` installs the newer release and
/// restarts the server process. Wired up in main.ts; absent in tests and
/// embedded runs.
export interface CodevisorServerUpdater {
  readonly check: (options?: {
    readonly force?: boolean
    readonly channel?: ServerUpdateChannel
  }) => Promise<UpdateInfo>
  readonly apply: (options?: { readonly channel?: ServerUpdateChannel }) => Promise<void>
}

export interface CodevisorServerConfig {
  readonly id: string
  readonly name: string
  readonly version: string
  readonly bootId: string
  readonly processId: number
  readonly appOwned: boolean
  readonly buildNumber?: number | undefined
  readonly sourceRevision?: string | undefined
  readonly serviceManaged: boolean
  readonly kind: ServerKind
  readonly host: string
  readonly port: number
  readonly worktreeNameStyle: "production" | "development"
  readonly auth: CodevisorServerAuthConfig
  /// Invoked after `POST /v1/shutdown` is acknowledged so the host process can
  /// exit (used by the macOS app to swap in an updated server runtime).
  readonly onShutdownRequested?: (() => void) | undefined
  readonly updater?: CodevisorServerUpdater | undefined
  /// Host power policy for active locally hosted turns. The production macOS
  /// server supplies a scoped idle-sleep assertion; other platforms/tests
  /// omit it.
  readonly sessionActivity?: SessionActivityController | undefined
  /// This machine's Codevisor Cloud device id (from `codevisor auth login`),
  /// advertised via /v1/info so clients can match this machine to its cloud
  /// presence entry instead of guessing by display name. When `cloud` is
  /// present its live device id wins over this boot-time snapshot.
  readonly cloudDeviceId?: string | undefined
  /// Live control over this machine's cloud registration (present when the
  /// hosting process can start/stop the cloud bridge at runtime). Lets the
  /// desktop app register this machine on the signed-in account via
  /// /v1/cloud/connect instead of requiring a separate `codevisor auth login`.
  readonly cloud?: CloudServerControl | undefined
}

export interface CloudServerControl {
  readonly deviceId: () => string | undefined
  readonly state: () => string | undefined
  /// "app" registrations follow the desktop app's account session; "external"
  /// ones (`codevisor auth login`, dev auto-provision) outlive it.
  readonly managedBy: () => "app" | "external" | undefined
  /// Provisions this machine on the account behind sessionToken and starts
  /// the bridge; resolves to the new cloud device id.
  readonly connect: (serverUrl: string, sessionToken: string) => Promise<string>
  /// Stops the bridge and forgets the stored credential.
  readonly disconnect: () => Promise<void>
  /// Adopts one server-accepted WebSocket as a direct sealed-channel pipe
  /// (see @codevisor/cloud-client DirectChannelHost). False when no bridge
  /// is running — the caller closes the socket.
  readonly acceptDirect?: (socket: import("@codevisor/cloud-client").CloudSocket) => boolean
}

export interface CodevisorServerServices {
  readonly db: CodevisorDatabaseService
  readonly attachments: AttachmentStore
  readonly agents: AgentRuntimeService
  readonly terminal: TerminalManagerService
  /// Full user shell environment for Git operations that can invoke checkout
  /// hooks and filters. GUI-launched macOS servers otherwise inherit a PATH
  /// that omits Homebrew tools such as git-lfs.
  readonly resolveGitEnvironment?: () => Promise<NodeJS.ProcessEnv>
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
  /// Plugin runtime: supervised local plugin servers whose panes are proxied
  /// under /v1/plugins/:id/app/*. Absent on hosts that don't support it —
  /// routes 501.
  readonly plugins?: PluginsManager
  /// Read-through cache over the hosted plugin registry index, so clients
  /// browse plugins through their machine instead of the cloud. Absent on
  /// hosts that don't support it — the registry route 501s.
  readonly pluginRegistry?: PluginRegistryClient
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

export interface RouteState {
  readonly pendingSessionCreates: Map<string, Promise<SessionSummary>>
  readonly pendingPromptActions: Set<string>
  readonly activePromptSessions: Set<string>
  /// Sessions whose prompt dispatch is held by a harness update gate, keyed
  /// to the harness they wait on. Cleared (and re-drained) on gate release.
  readonly gatedSessions: Map<string, string>
  /// Sessions with a live turn, tracked from `turnState` lifecycle events on
  /// the fanout. Unlike `activePromptSessions` (turns this process
  /// dispatched), this also sees turns the harness starts on its own — a
  /// task-notification follow-up after a background task finishes. Prompt
  /// dispatch holds while a session is in here.
  readonly activeTurnSessions: Set<string>
  /// Sessions whose queue drain was held because a turn was active.
  /// Re-drained when that turn's terminal event arrives.
  readonly turnHeldSessions: Set<string>
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

/// Attachment temp files older than this are swept at server start; agents
/// may read a materialized path late in a turn, so nothing is deleted while
/// a session could still reference it.
const ATTACHMENT_TEMP_MAX_AGE_MS = 7 * 24 * 60 * 60 * 1000

const attachmentsTempRoot = (): string => join(tmpdir(), "codevisor-attachments")

export const sanitizeFileName = (name: string): string => {
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

export const attachmentDiskFile = async (
  services: CodevisorServerServices,
  fileId: string
): Promise<{ readonly path: string; readonly metadata: FileMetadata }> => {
  const record = await run(services.db.getFileStorage(fileId))
  if (record === undefined) throw new HttpFailure(404, `File not found: ${fileId}`)
  const path = services.attachments.objectPath(record.metadata.sha256)
  if (record.storageState !== "sqlite") {
    try {
      const info = statSync(path)
      if (
        info.isFile() &&
        info.size === record.metadata.sizeBytes &&
        (record.storageState === "disk" || (await services.attachments.verify(record.metadata)))
      ) {
        return { path, metadata: record.metadata }
      }
    } catch {
      // A dual row can be reconstructed from its legacy bytes below.
    }
    if (record.storageState === "disk") {
      throw new AttachmentStoreError(`Attachment object is missing: ${fileId}`)
    }
  }
  await readAttachment(services, fileId)
  return { path, metadata: record.metadata }
}

export type ByteRange = { readonly start: number; readonly end: number }

export const requestedByteRange = (
  header: string | undefined,
  size: number
): ByteRange | "invalid" | undefined => {
  if (header === undefined) return undefined
  const match = /^bytes=(\d*)-(\d*)$/.exec(header.trim())
  if (match === null || size <= 0) return "invalid"
  /* v8 ignore next -- both capture groups are guaranteed by the matched expression. */
  const startText = match[1] ?? ""
  /* v8 ignore next -- both capture groups are guaranteed by the matched expression. */
  const endText = match[2] ?? ""
  if (startText.length === 0) {
    const suffix = Number(endText)
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return "invalid"
    return { start: Math.max(0, size - suffix), end: size - 1 }
  }
  const start = Number(startText)
  const requestedEnd = endText.length === 0 ? size - 1 : Number(endText)
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(requestedEnd) ||
    start < 0 ||
    start >= size ||
    requestedEnd < start
  ) {
    return "invalid"
  }
  return { start, end: Math.min(requestedEnd, size - 1) }
}

/// Materializes attachment bytes as temp files so path-based provider inputs
/// (Codex localImage, path notes for arbitrary files) can reference them.
/// Files are immutable, so an existing materialization is reused.
export const resolvePromptAttachments = async (
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

/// Archiving retires the session's runtime: the agent process shuts down and
/// every background-task terminal it registered is killed and removed — a
/// dev server must not keep running under an archived chat. Best-effort: the
/// archive itself must succeed even if the runtime is already gone.
export const archiveSessionRuntime = async (
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

/// Retires an archived session's git worktree once no other active session on
/// this server still relies on it. The files are captured as a snapshot commit
/// first, so archiving is lossless: uncommitted and untracked work survives in
/// `refs/codevisor/archived/<worktreeId>` and can be restored on unarchive.
///
/// The `worktrees` row and the branch are both dropped, which is what returns
/// the (finite) worktree name to the pool. The `archived_worktrees` record is
/// what restore navigates by.
///
/// Sessions in non-git projects carry no worktree name and return immediately:
/// their cwd is the user's own project folder, which we must never touch.
export const archiveSessionWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  session: SessionSummary
): Promise<ReadonlyArray<string>> => {
  const worktreeName = session.worktreeName
  if (worktreeName === undefined) {
    return []
  }
  const stillInUse = (await run(services.db.listSessions)).some(
    (candidate) =>
      !candidate.isArchived &&
      candidate.projectId === session.projectId &&
      candidate.worktreeName === worktreeName
  )
  if (stillInUse) {
    return []
  }
  const worktree = (await run(services.db.listWorktrees(session.projectId))).find(
    (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
  )
  if (worktree === undefined) {
    return []
  }
  const project = await getProjectOrFail(services.db, session.projectId)
  const location = localLocationOrFail(serverId, project)
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  const snapshot = await archiveWorktreeFiles(
    location.folderPath,
    worktree.path,
    worktree.id,
    worktree.branch,
    removeWorktree,
    environment
  )
  await run(
    services.db.createArchivedWorktree({
      id: worktree.id,
      projectId: worktree.projectId,
      serverId: worktree.serverId,
      originalName: worktree.name,
      branch: worktree.branch,
      parentSha: snapshot.parentSha,
      snapshotRef: snapshot.snapshotRef,
      createdAt: isoTimestamp()
    })
  )
  await run(services.db.deleteWorktree(worktree.id))
  return snapshot.ignoredPaths
}

/// Rebuilds an unarchived session's worktree from its snapshot.
///
/// Restore may hand back a DIFFERENT worktree name than the session had: the
/// original is freed at archive time and can legitimately be claimed while the
/// chat sits archived. The session's `worktree_name` is rewritten to match, as
/// is every other archived session that shared that worktree, so they all
/// still resolve to one directory if they are later restored too.
export const restoreSessionWorktree = async (
  services: CodevisorServerServices,
  serverId: string,
  session: SessionSummary
): Promise<{ readonly session: SessionSummary; readonly restoredFiles: boolean }> => {
  const worktreeName = session.worktreeName
  if (worktreeName === undefined) {
    return { session, restoredFiles: true }
  }
  // Our own snapshot wins over any worktree that merely shares the name.
  // Archiving frees the name, so an unrelated worktree can be created under
  // it in the meantime; treating that as "already live" would silently point
  // the chat at a stranger's files and strand the snapshot forever.
  const archived = await run(
    services.db.findArchivedWorktree(session.projectId, serverId, worktreeName)
  )
  if (archived === undefined) {
    // No snapshot of our own: either another session in this worktree was
    // unarchived first (reattach to it), or the archive predates snapshots,
    // in which case the chat still unarchives but its cwd may not exist.
    const existing = (await run(services.db.listWorktrees(session.projectId))).find(
      (candidate) => candidate.serverId === serverId && candidate.name === worktreeName
    )
    return { session, restoredFiles: existing !== undefined }
  }
  const project = await getProjectOrFail(services.db, session.projectId)
  const location = localLocationOrFail(serverId, project)
  const environment = await (services.resolveGitEnvironment?.() ?? Promise.resolve(process.env))
  const taken = new Set(
    (await run(services.db.listWorktrees(session.projectId)))
      .filter((candidate) => candidate.serverId === serverId)
      .map((candidate) => candidate.name)
  )
  const restored = await restoreWorktree({
    repoDir: location.folderPath,
    worktreePathFor: (name) => worktreePath(session.projectId, name),
    originalName: archived.originalName,
    parentSha: archived.parentSha,
    snapshotRef: archived.snapshotRef,
    takenNames: taken,
    env: environment
  })
  await run(
    services.db.createWorktree(session.projectId, restored.name, restored.branch, archived.id)
  )
  await run(services.db.deleteArchivedWorktree(archived.id))
  await deleteSnapshot(location.folderPath, archived.id, environment)

  let updated = session
  if (restored.name !== worktreeName) {
    for (const candidate of await run(services.db.listSessions)) {
      if (candidate.projectId !== session.projectId || candidate.worktreeName !== worktreeName) {
        continue
      }
      const next = await run(
        services.db.updateSession(candidate.id, { worktreeName: restored.name })
      )
      if (candidate.id === session.id) {
        updated = next
      }
    }
  }
  return { session: updated, restoredFiles: restored.restoredFromSnapshot }
}

/// Archiving a project or workspace flips its sessions' flags inside one
/// database transaction, but the runtime consequences live outside it: agent
/// processes to stop, background terminals to kill, worktrees to snapshot and
/// remove. This replays those effects for exactly the sessions whose archived
/// state actually changed, and fans out a per-session event so clients can
/// move the rows between sidebar sections.
///
/// Worktree bookkeeping falls out naturally: the cascade has already flagged
/// every session archived, so the first one reaching `archiveSessionWorktree`
/// finds no active user and takes the snapshot; the rest short-circuit.
/// Fans out `workspace.updated` for workspaces a cascade archived or revived,
/// so a client's archived section stays in step without a full refetch.
export const publishChangedWorkspaces = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  before: ReadonlyArray<Workspace>
): Promise<void> => {
  const previous = new Map(before.map((workspace) => [workspace.id, workspace.isArchived]))
  for (const workspace of await run(services.db.listWorkspaces)) {
    if (previous.get(workspace.id) === workspace.isArchived) {
      continue
    }
    await appendAndPublish(services.db, fanout, "workspace.updated", workspace.id, workspace)
  }
}

export const applyCascadedSessionEffects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig,
  before: ReadonlyArray<SessionSummary>
): Promise<void> => {
  const previous = new Map(before.map((session) => [session.id, session.isArchived]))
  for (const current of await run(services.db.listSessions)) {
    const wasArchived = previous.get(current.id)
    if (wasArchived === undefined || wasArchived === current.isArchived) {
      continue
    }
    let session = current
    if (session.isArchived) {
      await archiveSessionRuntime(services, session)
      await archiveSessionWorktree(services, config.id, session)
    } else {
      session = (await restoreSessionWorktree(services, config.id, session)).session
    }
    await appendAndPublish(
      services.db,
      fanout,
      session.isArchived ? "session.archived" : "session.unarchived",
      session.id,
      session
    )
  }
}

/* v8 ignore next 3 -- defensive: shared swallow for fire-and-forget event/drain failures. */
export const swallowError = (): undefined => {
  return undefined
}

export const authorize = async (
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

export const getProjectOrFail = async (
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

export const localLocationOrFail = (serverId: string, project: Project): ProjectLocation => {
  const location = project.locations.find((candidate) => candidate.serverId === serverId)
  if (location === undefined) {
    throw new HttpFailure(400, `Project has no folder on this machine: ${project.id}`)
  }
  return location
}

export const existingDirectory = (folderPath: string | null): string | undefined => {
  if (folderPath === null || folderPath.length === 0) {
    return undefined
  }
  try {
    return statSync(folderPath).isDirectory() ? folderPath : undefined
  } catch {
    return undefined
  }
}

export const assertLocationFolderExists = (location: ProjectLocation): void => {
  if (existingDirectory(location.folderPath) === undefined) {
    throw new HttpFailure(400, `Project folder does not exist: ${location.folderPath}`)
  }
}

export const appendAndPublish = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  kind: EventEnvelope["kind"],
  subjectId: string,
  payload: unknown
): Promise<EventEnvelope> => {
  const affectsAttention =
    kind === "session.output" ||
    kind === "session.updated" ||
    kind === "session.error" ||
    kind === "session.authRequired"
  const before = affectsAttention ? await run(db.getSessionSummary(subjectId)) : undefined
  const event = await run(db.appendEvent(kind, subjectId, payload))
  await run(fanout.publish(event))
  if (before !== undefined) {
    const after = await run(db.getSessionSummary(subjectId))
    if (sessionAttentionSignature(before) !== sessionAttentionSignature(after)) {
      const attentionEvent = await run(
        db.appendEvent("session.attention.updated", subjectId, after)
      )
      await run(fanout.publish(attentionEvent))
    }
  }
  return event
}

const sessionAttentionSignature = (session: SessionSummary): string =>
  JSON.stringify([
    session.latestAttentionSequence,
    session.lastSeenAttentionSequence,
    session.unreadCount,
    session.hasUnreadError,
    session.actionRequired,
    session.actionRequiredKind,
    session.pendingPlanApproval,
    session.sidebarState,
    session.sidebarStateChangedAt
  ])

export const readSchema = async <S extends Schema.ConstraintDecoder<unknown>>(
  request: IncomingMessage,
  schema: S
): Promise<S["Type"]> => {
  try {
    return decode(schema)(await readJson(request))
  } catch (cause) {
    throw new HttpFailure(400, failureMessage(cause))
  }
}

export const readJson = async (request: IncomingMessage): Promise<unknown> => {
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

export const writeJson = (response: ServerResponse, status: number, body: unknown): void => {
  if (status === 204) {
    response.writeHead(status)
    response.end()
    return
  }
  response.writeHead(status, { "Content-Type": "application/json" })
  response.end(JSON.stringify(body))
}

export const writeFailure = (response: ServerResponse, cause: unknown): void => {
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
  if (cause instanceof PluginsError) {
    const status =
      cause.code === "invalid"
        ? 400
        : cause.code === "notFound"
          ? 404
          : cause.code === "unavailable"
            ? 503
            : 409
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

export const parseRequestUrl = (request: IncomingMessage): URL => {
  /* v8 ignore next -- Node HTTP requests always provide url and host in these paths. */
  return new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`)
}

/// Resources whose ids are canonically lowercase uuids (Swift clients render
/// the same uuid uppercase). Their path parameters are normalized at the
/// routing boundary so one chat can never split into case-twin database rows,
/// in-memory transport keys, or event subjects. Other path parameters
/// (queue-item ids, question ids, MCP ids, ...) are opaque client tokens and
/// pass through byte-identical.
const canonicalIdResources = new Set(["sessions", "projects", "workspaces", "worktrees"])

const canonicalRouteCapture = (previousPatternPart: string | undefined, value: string): string =>
  previousPatternPart !== undefined && canonicalIdResources.has(previousPatternPart)
    ? value.toLowerCase()
    : value

export const matchRoute = (pathname: string, pattern: string): string | undefined => {
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
      captured = canonicalRouteCapture(patternParts[index - 1], decodeURIComponent(pathPart))
    } else if (patternPart !== pathPart) {
      return undefined
    }
  }
  return captured
}

export const matchRouteParams = (
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
      params[patternPart.slice(1)] = canonicalRouteCapture(
        patternParts[index - 1],
        decodeURIComponent(pathPart)
      )
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

export const isLocalhost = (address: string | undefined): boolean =>
  localhostAddresses.has(String(address))

/* v8 ignore next -- route/runtime failures use Error-compatible values. */
export const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export class HttpFailure extends Error {
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
