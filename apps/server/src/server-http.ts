import type { EventEnvelope, Project, ProjectLocation, SessionSummary } from "@codevisor/api"
import { decode } from "@codevisor/api"
import { AttachmentStoreError } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { CloneError, GitError } from "@codevisor/worktrees"
import type { IncomingMessage, ServerResponse } from "node:http"
import { statSync } from "node:fs"
import { Effect, Schema } from "effect"
import { NativeMcpError } from "@codevisor/mcp"
import { SkillsError } from "@codevisor/skills"
import { PluginsError } from "@codevisor/plugins"
import { EventFanout } from "./server-context-types.js"
import type { CodevisorServerConfig } from "./server-context-types.js"

/// HTTP plumbing shared by every route: auth, JSON I/O, failure mapping,
/// route matching, and the common lookup-or-404 helpers.

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
