import { statSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"

import type { EventEnvelope, Project, ProjectLocation, SessionSummary } from "@codevisor/api"
import { decode } from "@codevisor/api"
import { AttachmentStoreError } from "@codevisor/db"
import type { CodevisorDatabaseService } from "@codevisor/db"
import { NativeMcpError } from "@codevisor/mcp"
import { PluginsError } from "@codevisor/plugins"
import { SkillsError } from "@codevisor/skills"
import { CloneError, GitError } from "@codevisor/worktrees"
import { Effect, Schema } from "effect"

import { EventFanout } from "./server-context-types.js"
import type { CodevisorServerConfig } from "./server-context-types.js"

/* v8 ignore next 3 */
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
    kind === "session.queue.updated" ||
    kind === "session.authRequired" ||
    kind === "bot.message"
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
    session.latestBotMessage,
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
    /* v8 ignore next */
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

const skillsFailureStatus = (cause: SkillsError) => {
  if (cause.code === "invalid") return 400
  if (cause.code === "notFound") return 404
  return 409
}

const pluginsFailureStatus = (cause: PluginsError) => {
  if (cause.code === "invalid") return 400
  if (cause.code === "notFound") return 404
  if (cause.code === "unavailable") return 503
  return 409
}

const nativeMcpFailureStatus = (cause: NativeMcpError) => {
  if (cause.code === "notFound") return 404
  if (cause.code === "conflict") return 409
  return 422
}

export const writeFailure = (response: ServerResponse, cause: unknown): void => {
  /* v8 ignore next */
  if (response.headersSent) {
    response.end()
    return
  }
  if (cause instanceof HttpFailure) {
    writeJson(response, cause.status, {
      error: cause.message,
      ...(cause.code === undefined ? {} : { code: cause.code }),
      ...(cause.details === undefined ? {} : { details: cause.details })
    })
    return
  }
  if (cause instanceof AttachmentStoreError) {
    writeJson(response, 500, { error: cause.message })
    return
  }
  if (cause instanceof SkillsError) {
    const status = skillsFailureStatus(cause)
    writeJson(response, status, { code: cause.code, error: cause.message })
    return
  }
  if (cause instanceof PluginsError) {
    const status = pluginsFailureStatus(cause)
    writeJson(response, status, { code: cause.code, error: cause.message })
    return
  }
  if (cause instanceof NativeMcpError) {
    const status = nativeMcpFailureStatus(cause)
    writeJson(response, status, { code: cause.code, error: cause.message })
    return
  }
  if (cause instanceof CloneError) {
    writeJson(response, 422, {
      error: cause.message,
      /* v8 ignore next */
      ...(cause.code === undefined ? {} : { code: cause.code })
    })
    return
  }
  /* v8 ignore next 3 */
  if (cause instanceof GitError) {
    writeJson(response, 422, { error: cause.message })
    return
  }
  writeJson(response, 500, { error: failureMessage(cause) })
}

export const parseRequestUrl = (request: IncomingMessage): URL => {
  /* v8 ignore next */
  return new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`)
}

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
  for (const [index, pathPart] of pathParts.entries()) {
    const patternPart = patternParts[index]
    if (patternPart?.startsWith(":")) {
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
  for (const [index, pathPart] of pathParts.entries()) {
    const patternPart = patternParts[index]
    if (patternPart?.startsWith(":")) {
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

/* v8 ignore next */
export const failureMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

export const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

export class HttpFailure extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly code?: string,
    readonly details?: Readonly<Record<string, unknown>>
  ) {
    super(message)
  }
}
