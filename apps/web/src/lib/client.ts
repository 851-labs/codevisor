// Typed HTTP client for the herdman server, mirroring the Swift
// HerdManServerClient method-for-method. Responses are decoded with the
// @herdman/api Effect schemas so the wire contract stays single-sourced.
// Effect imports stay confined to this module (and session-events.ts).
import {
  type AttachmentRef,
  BranchDiffTotals,
  type BranchDiffTotals as BranchDiffTotalsType,
  type CancelRequest,
  type CreateSessionRequest,
  type CreateProjectRequest,
  type CreateWorktreeRequest,
  decode,
  EventEnvelope,
  FileMetadata,
  type FileMetadata as FileMetadataType,
  type GoalStatus,
  Harness,
  HealthResponse,
  PairingTokenResponse,
  PromptAcceptedResponse,
  type PromptRequest,
  PromptQueueItem,
  type QuestionAnswerEntry,
  ServerCapabilities,
  ServerInfo,
  SessionDetail,
  SessionGoal,
  type SessionGoal as SessionGoalType,
  SessionSummary,
  type SetConfigRequest,
  type SetGoalRequest,
  type SetModeRequest,
  type SetQuestionAnswerRequest,
  TerminalCreateRequest,
  TerminalCreateResponse,
  type UpdateHarnessRequest,
  type UpdateQueuedPromptRequest,
  type UpdateSessionRequest,
  type UpdateProjectRequest,
  Project,
  Worktree
} from "@herdman/api"
import { Schema } from "effect"

import type { ServerConfig } from "./server-config"

export class HerdManHttpError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message === "" ? `HTTP ${status}` : message)
    this.name = "HerdManHttpError"
    this.status = status
  }
}

const decodeHealth = decode(HealthResponse)
const decodeInfo = decode(ServerInfo)
const decodeCapabilities = decode(ServerCapabilities)
const decodeHarness = decode(Harness)
const decodeHarnesses = decode(Schema.Array(Harness))
/// The project's folder on the connected server. The web client talks to a
/// single server, whose location is the only one it can act on.
export const projectFolderPath = (project: Project): string | undefined =>
  project.locations[0]?.folderPath

const decodeProject = decode(Project)
const decodeProjects = decode(Schema.Array(Project))
const decodeWorktree = decode(Worktree)
const decodeSession = decode(SessionSummary)
const decodeSessions = decode(Schema.Array(SessionSummary))
const decodeSessionDetail = decode(SessionDetail)
const decodeBranchDiffTotals = decode(Schema.NullOr(BranchDiffTotals))
const decodeGoal = decode(SessionGoal)
const decodeEvents = decode(Schema.Array(EventEnvelope))
const decodeFileMetadata = decode(FileMetadata)
const decodePromptAccepted = decode(PromptAcceptedResponse)
const decodeQueueItem = decode(PromptQueueItem)
const decodeQueue = decode(Schema.Array(PromptQueueItem))
const decodeTerminalCreated = decode(TerminalCreateResponse)
const decodePairingToken = decode(PairingTokenResponse)

export class HerdManClient {
  readonly config: ServerConfig
  private readonly fetchFn: typeof fetch

  constructor(config: ServerConfig, fetchFn: typeof fetch = (...args) => fetch(...args)) {
    this.config = config
    this.fetchFn = fetchFn
  }

  health(): Promise<HealthResponse> {
    return this.get("/v1/health", decodeHealth)
  }

  info(): Promise<ServerInfo> {
    return this.get("/v1/info", decodeInfo)
  }

  issuePairingToken(): Promise<PairingTokenResponse> {
    return this.send("/v1/auth/pairing-token", "POST", undefined, decodePairingToken)
  }

  capabilities(cwd: string): Promise<ServerCapabilities> {
    return this.get(`/v1/capabilities?cwd=${encodeURIComponent(cwd)}`, decodeCapabilities)
  }

  listHarnesses(): Promise<readonly Harness[]> {
    return this.get("/v1/harnesses", decodeHarnesses)
  }

  setHarnessEnabled(id: string, enabled: boolean): Promise<Harness> {
    const body: UpdateHarnessRequest = { enabled }
    return this.send(`/v1/harnesses/${encodeURIComponent(id)}`, "PATCH", body, decodeHarness)
  }

  listProjects(): Promise<readonly Project[]> {
    return this.get("/v1/projects", decodeProjects)
  }

  createProject(request: CreateProjectRequest): Promise<Project> {
    return this.send("/v1/projects", "POST", request, decodeProject)
  }

  updateProject(id: string, request: UpdateProjectRequest): Promise<Project> {
    return this.send(`/v1/projects/${encodeURIComponent(id)}`, "PATCH", request, decodeProject)
  }

  deleteProject(id: string): Promise<void> {
    return this.sendVoid(`/v1/projects/${encodeURIComponent(id)}`, "DELETE")
  }

  createWorktree(projectId: string, request: CreateWorktreeRequest): Promise<Worktree> {
    return this.send(
      `/v1/projects/${encodeURIComponent(projectId)}/worktrees`,
      "POST",
      request,
      decodeWorktree
    )
  }

  listSessions(): Promise<readonly SessionSummary[]> {
    return this.get("/v1/sessions", decodeSessions)
  }

  sessionDetail(id: string): Promise<SessionDetail> {
    return this.get(`/v1/sessions/${encodeURIComponent(id)}`, decodeSessionDetail)
  }

  sessionBranchDiff(id: string): Promise<BranchDiffTotalsType | null> {
    return this.get(`/v1/sessions/${encodeURIComponent(id)}/branch-diff`, decodeBranchDiffTotals)
  }

  sessionEvents(id: string): Promise<readonly EventEnvelope[]> {
    return this.get(`/v1/sessions/${encodeURIComponent(id)}/events`, decodeEvents)
  }

  createSession(request: CreateSessionRequest): Promise<SessionSummary> {
    return this.send("/v1/sessions", "POST", request, decodeSession)
  }

  updateSession(id: string, request: UpdateSessionRequest): Promise<SessionSummary> {
    return this.send(`/v1/sessions/${encodeURIComponent(id)}`, "PATCH", request, decodeSession)
  }

  deleteSession(id: string): Promise<void> {
    return this.sendVoid(`/v1/sessions/${encodeURIComponent(id)}`, "DELETE")
  }

  promptSession(
    id: string,
    text: string,
    attachments?: readonly AttachmentRef[]
  ): Promise<PromptAcceptedResponse> {
    const body: PromptRequest = {
      text,
      clientActionId: crypto.randomUUID(),
      ...(attachments == null || attachments.length === 0 ? {} : { attachments })
    }
    return this.send(
      `/v1/sessions/${encodeURIComponent(id)}/prompt`,
      "POST",
      body,
      decodePromptAccepted
    )
  }

  async uploadFile(file: File): Promise<FileMetadataType> {
    const headers: Record<string, string> = {
      Accept: "application/json",
      "Content-Type": file.type === "" ? "application/octet-stream" : file.type
    }
    if (this.config.token != null) {
      headers.Authorization = `Bearer ${this.config.token}`
    }
    const response = await this.fetchFn(
      `${this.config.baseUrl}/v1/files?name=${encodeURIComponent(file.name)}`,
      {
        method: "POST",
        headers,
        body: file
      }
    )
    const text = await response.text()
    if (!response.ok) {
      throw new HerdManHttpError(response.status, text)
    }
    return decodeFileMetadata(JSON.parse(text) as unknown)
  }

  async downloadFile(fileId: string): Promise<Blob> {
    const headers: Record<string, string> = { Accept: "*/*" }
    if (this.config.token != null) {
      headers.Authorization = `Bearer ${this.config.token}`
    }
    const response = await this.fetchFn(
      `${this.config.baseUrl}/v1/files/${encodeURIComponent(fileId)}`,
      { method: "GET", headers }
    )
    if (!response.ok) {
      throw new HerdManHttpError(response.status, await response.text())
    }
    return response.blob()
  }

  promptQueue(id: string): Promise<readonly PromptQueueItem[]> {
    return this.get(`/v1/sessions/${encodeURIComponent(id)}/queue`, decodeQueue)
  }

  updateQueuedPrompt(
    sessionId: string,
    queueItemId: string,
    text: string
  ): Promise<PromptQueueItem> {
    const body: UpdateQueuedPromptRequest = { text }
    return this.send(
      `/v1/sessions/${encodeURIComponent(sessionId)}/queue/${encodeURIComponent(queueItemId)}`,
      "PATCH",
      body,
      decodeQueueItem
    )
  }

  deleteQueuedPrompt(sessionId: string, queueItemId: string): Promise<void> {
    return this.sendVoid(
      `/v1/sessions/${encodeURIComponent(sessionId)}/queue/${encodeURIComponent(queueItemId)}`,
      "DELETE"
    )
  }

  cancelSession(id: string): Promise<void> {
    const body: CancelRequest = { clientActionId: crypto.randomUUID() }
    return this.sendVoid(`/v1/sessions/${encodeURIComponent(id)}/cancel`, "POST", body)
  }

  answerSessionQuestion(
    id: string,
    questionId: string,
    outcome: "answered" | "cancelled",
    answers?: Record<string, QuestionAnswerEntry>
  ): Promise<void> {
    const body: SetQuestionAnswerRequest = {
      outcome,
      answers,
      clientActionId: crypto.randomUUID()
    }
    return this.sendVoid(
      `/v1/sessions/${encodeURIComponent(id)}/questions/${encodeURIComponent(questionId)}/answer`,
      "POST",
      body
    )
  }

  setSessionGoal(
    id: string,
    request: { objective?: string; status?: GoalStatus; tokenBudget?: number | null }
  ): Promise<SessionGoalType> {
    const body: SetGoalRequest = { ...request, clientActionId: crypto.randomUUID() }
    return this.send(`/v1/sessions/${encodeURIComponent(id)}/goal`, "POST", body, decodeGoal)
  }

  clearSessionGoal(id: string): Promise<void> {
    return this.sendVoid(`/v1/sessions/${encodeURIComponent(id)}/goal`, "DELETE")
  }

  setSessionMode(id: string, modeId: string): Promise<void> {
    const body: SetModeRequest = { modeId, clientActionId: crypto.randomUUID() }
    return this.sendVoid(`/v1/sessions/${encodeURIComponent(id)}/mode`, "POST", body)
  }

  setSessionConfig(id: string, configId: string, value: string): Promise<void> {
    const body: SetConfigRequest = { configId, value, clientActionId: crypto.randomUUID() }
    return this.sendVoid(`/v1/sessions/${encodeURIComponent(id)}/config`, "POST", body)
  }

  createTerminal(request: TerminalCreateRequest): Promise<TerminalCreateResponse> {
    return this.send("/v1/terminals", "POST", request, decodeTerminalCreated)
  }

  requestShutdown(): Promise<void> {
    return this.sendVoid("/v1/shutdown", "POST")
  }

  private get<T>(path: string, decodeBody: (input: unknown) => T): Promise<T> {
    return this.send(path, "GET", undefined, decodeBody)
  }

  private async send<T>(
    path: string,
    method: string,
    body: unknown,
    decodeBody: (input: unknown) => T
  ): Promise<T> {
    const data = await this.perform(path, method, body)
    return decodeBody(data)
  }

  private async sendVoid(path: string, method: string, body?: unknown): Promise<void> {
    await this.perform(path, method, body)
  }

  private async perform(path: string, method: string, body: unknown): Promise<unknown> {
    const headers: Record<string, string> = { Accept: "application/json" }
    if (this.config.token != null) {
      headers.Authorization = `Bearer ${this.config.token}`
    }
    let requestBody: string | undefined
    if (body !== undefined) {
      headers["Content-Type"] = "application/json"
      requestBody = JSON.stringify(body)
    }
    const response = await this.fetchFn(`${this.config.baseUrl}${path}`, {
      method,
      headers,
      body: requestBody
    })
    const text = await response.text()
    if (!response.ok) {
      throw new HerdManHttpError(response.status, text)
    }
    if (text === "") return undefined
    try {
      return JSON.parse(text) as unknown
    } catch {
      return undefined
    }
  }
}
