import { Schema } from "effect"

export const isoTimestamp = (): string => new Date().toISOString()

export const ServerKind = Schema.Literals(["local", "remote"])
export type ServerKind = typeof ServerKind.Type

export const SessionOrigin = Schema.Literals(["herdman", "imported"])
export type SessionOrigin = typeof SessionOrigin.Type

export const HarnessReadiness = Schema.Struct({
  state: Schema.Literals(["ready", "unavailable"]),
  detail: Schema.optional(Schema.String)
})
export type HarnessReadiness = typeof HarnessReadiness.Type

export const Harness = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  symbolName: Schema.String,
  source: Schema.String,
  launchKind: Schema.Literals(["executable", "npx", "uvx", "unknown"]),
  enabled: Schema.Boolean,
  readiness: HarnessReadiness
})
export type Harness = typeof Harness.Type

export const UpdateHarnessRequest = Schema.Struct({
  enabled: Schema.Boolean
})
export type UpdateHarnessRequest = typeof UpdateHarnessRequest.Type

export const Workspace = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  folderPath: Schema.String,
  isArchived: Schema.Boolean,
  symbolName: Schema.String,
  origin: SessionOrigin,
  createdAt: Schema.String
})
export type Workspace = typeof Workspace.Type

export const CreateWorkspaceRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  folderPath: Schema.String,
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  createdAt: Schema.optional(Schema.String)
})
export type CreateWorkspaceRequest = typeof CreateWorkspaceRequest.Type

export const UpdateWorkspaceRequest = Schema.Struct({
  name: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  symbolName: Schema.optional(Schema.String)
})
export type UpdateWorkspaceRequest = typeof UpdateWorkspaceRequest.Type

export const SessionUsage = Schema.Struct({
  used: Schema.optional(Schema.Number),
  size: Schema.optional(Schema.Number),
  costAmount: Schema.optional(Schema.Number),
  costCurrency: Schema.optional(Schema.String)
})
export type SessionUsage = typeof SessionUsage.Type

export const SessionSummary = Schema.Struct({
  id: Schema.String,
  workspaceId: Schema.String,
  serverId: Schema.String,
  harnessId: Schema.String,
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.String,
  origin: SessionOrigin,
  isArchived: Schema.Boolean,
  createdAt: Schema.String,
  updatedAt: Schema.optional(Schema.String),
  usage: Schema.optional(SessionUsage)
})
export type SessionSummary = typeof SessionSummary.Type

export const ConversationRole = Schema.Literals(["user", "assistant", "system"])
export type ConversationRole = typeof ConversationRole.Type

export const ConversationItem = Schema.Struct({
  id: Schema.String,
  role: ConversationRole,
  text: Schema.String,
  createdAt: Schema.String,
  isGenerating: Schema.Boolean
})
export type ConversationItem = typeof ConversationItem.Type

export const SessionDetail = Schema.Struct({
  session: SessionSummary,
  conversation: Schema.Array(ConversationItem),
  eventCursor: Schema.Number
})
export type SessionDetail = typeof SessionDetail.Type

export const CreateSessionRequest = Schema.Struct({
  id: Schema.optional(Schema.String),
  workspaceId: Schema.String,
  harnessId: Schema.String,
  agentSessionId: Schema.optional(Schema.String),
  title: Schema.optional(Schema.String),
  origin: Schema.optional(SessionOrigin),
  isArchived: Schema.optional(Schema.Boolean),
  createdAt: Schema.optional(Schema.String),
  updatedAt: Schema.optional(Schema.String)
})
export type CreateSessionRequest = typeof CreateSessionRequest.Type

export const UpdateSessionRequest = Schema.Struct({
  agentSessionId: Schema.optional(Schema.String),
  isArchived: Schema.optional(Schema.Boolean),
  title: Schema.optional(Schema.String)
})
export type UpdateSessionRequest = typeof UpdateSessionRequest.Type

export const PromptRequest = Schema.Struct({
  text: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type PromptRequest = typeof PromptRequest.Type

export const CancelRequest = Schema.Struct({
  clientActionId: Schema.optional(Schema.String)
})
export type CancelRequest = typeof CancelRequest.Type

export const SetModeRequest = Schema.Struct({
  modeId: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type SetModeRequest = typeof SetModeRequest.Type

export const SetConfigRequest = Schema.Struct({
  configId: Schema.String,
  value: Schema.String,
  clientActionId: Schema.optional(Schema.String)
})
export type SetConfigRequest = typeof SetConfigRequest.Type

export const HealthResponse = Schema.Struct({
  ok: Schema.Boolean,
  version: Schema.String,
  database: Schema.Literals(["ready", "migrating"])
})
export type HealthResponse = typeof HealthResponse.Type

export const ServerInfo = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  kind: ServerKind,
  version: Schema.String,
  platform: Schema.String,
  bindHost: Schema.String
})
export type ServerInfo = typeof ServerInfo.Type

export const UpdateInfo = Schema.Struct({
  currentVersion: Schema.String,
  latestVersion: Schema.String,
  updateAvailable: Schema.Boolean,
  channel: Schema.String,
  checkedAt: Schema.optional(Schema.String),
  migrationState: Schema.Literals(["idle", "running", "failed"])
})
export type UpdateInfo = typeof UpdateInfo.Type

export const PairingTokenResponse = Schema.Struct({
  token: Schema.String,
  createdAt: Schema.String
})
export type PairingTokenResponse = typeof PairingTokenResponse.Type

export const EventKind = Schema.Literals([
  "workspace.created",
  "workspace.updated",
  "workspace.deleted",
  "session.created",
  "session.updated",
  "session.archived",
  "session.deleted",
  "session.output",
  "session.error",
  "terminal.output",
  "terminal.exit",
  "update.changed"
])
export type EventKind = typeof EventKind.Type

export const EventEnvelope = Schema.Struct({
  id: Schema.Number,
  serverId: Schema.String,
  kind: EventKind,
  subjectId: Schema.String,
  createdAt: Schema.String,
  payload: Schema.Unknown
})
export type EventEnvelope = typeof EventEnvelope.Type

export const TerminalCreateRequest = Schema.Struct({
  sessionId: Schema.String,
  cwd: Schema.String,
  cols: Schema.Number,
  rows: Schema.Number,
  shell: Schema.optional(Schema.String)
})
export type TerminalCreateRequest = typeof TerminalCreateRequest.Type

export const TerminalCreateResponse = Schema.Struct({
  terminalId: Schema.String,
  websocketPath: Schema.String,
  nextOutputSeq: Schema.Number
})
export type TerminalCreateResponse = typeof TerminalCreateResponse.Type

const TerminalClientFrameBase = {
  clientId: Schema.String,
  clientSeq: Schema.Number
} as const

export const TerminalClientFrame = Schema.Union([
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("input"), data: Schema.String }),
  Schema.Struct({
    ...TerminalClientFrameBase,
    type: Schema.Literal("resize"),
    cols: Schema.Number,
    rows: Schema.Number
  }),
  Schema.Struct({ ...TerminalClientFrameBase, type: Schema.Literal("close") })
])
export type TerminalClientFrame = typeof TerminalClientFrame.Type

export const TerminalServerFrame = Schema.Union([
  Schema.Struct({ type: Schema.Literal("output"), seq: Schema.Number, data: Schema.String }),
  Schema.Struct({
    type: Schema.Literal("exit"),
    seq: Schema.Number,
    exitCode: Schema.optional(Schema.Number)
  }),
  Schema.Struct({ type: Schema.Literal("error"), seq: Schema.Number, message: Schema.String })
])
export type TerminalServerFrame = typeof TerminalServerFrame.Type

export const HerdManOpenApi = Schema.Struct({
  openapi: Schema.Literal("3.1.0"),
  info: Schema.Struct({
    title: Schema.String,
    version: Schema.String
  }),
  paths: Schema.Record(Schema.String, Schema.Unknown)
})
export type HerdManOpenApi = typeof HerdManOpenApi.Type

export const endpoints = [
  "GET /v1/health",
  "GET /v1/info",
  "GET /v1/update",
  "POST /v1/auth/pairing-token",
  "GET /v1/workspaces",
  "POST /v1/workspaces",
  "PATCH /v1/workspaces/:id",
  "DELETE /v1/workspaces/:id",
  "GET /v1/harnesses",
  "PATCH /v1/harnesses/:id",
  "GET /v1/sessions",
  "POST /v1/sessions",
  "GET /v1/sessions/:id",
  "PATCH /v1/sessions/:id",
  "DELETE /v1/sessions/:id",
  "POST /v1/sessions/:id/prompt",
  "POST /v1/sessions/:id/cancel",
  "POST /v1/sessions/:id/mode",
  "POST /v1/sessions/:id/config",
  "GET /v1/events",
  "POST /v1/terminals",
  "GET /v1/terminals/:id/socket"
] as const

export const makeOpenApiDocument = (version: string): HerdManOpenApi => ({
  openapi: "3.1.0",
  info: {
    title: "HerdMan Server API",
    version
  },
  paths: Object.fromEntries(endpoints.map((endpoint) => [endpoint, { "x-herdman-endpoint": true }]))
})

export const decode =
  <S extends Schema.ConstraintDecoder<unknown>>(schema: S) =>
  (input: unknown): S["Type"] =>
    Schema.decodeUnknownSync(schema)(input)

export const encode =
  <S extends Schema.ConstraintEncoder<unknown>>(schema: S) =>
  (input: S["Type"]): S["Encoded"] =>
    Schema.encodeSync(schema)(input)
