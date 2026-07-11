import { Schema } from "effect"

import {
  AgentSessionSummary,
  BranchDiffTotals,
  CancelRequest,
  CreateHarnessAccountRequest,
  CreateProjectRequest,
  CreateSessionRequest,
  CreateWorktreeRequest,
  EventEnvelope,
  FileMetadata,
  Harness,
  HarnessAccount,
  HarnessAuthFlow,
  HealthResponse,
  PairingTokenResponse,
  Project,
  PromptAcceptedResponse,
  PromptQueueItem,
  PromptRequest,
  ServerCapabilities,
  ServerInfo,
  SessionDetail,
  SessionGoal,
  SessionSummary,
  SetConfigRequest,
  SetGoalRequest,
  SetModeRequest,
  SetQuestionAnswerRequest,
  StartHarnessLoginRequest,
  TerminalClientFrame,
  TerminalCreateRequest,
  TerminalCreateResponse,
  TerminalServerFrame,
  TranscriptItemDetails,
  TranscriptPage,
  UpdateHarnessAccountRequest,
  UpdateHarnessRequest,
  UpdateInfo,
  UpdateProjectRequest,
  UpdateQueuedPromptRequest,
  UpdateSessionRequest,
  Worktree
} from "./index.js"

export interface HerdManOpenApi {
  readonly openapi: "3.1.0"
  readonly info: {
    readonly title: string
    readonly version: string
    readonly description: string
  }
  readonly servers: ReadonlyArray<Record<string, unknown>>
  readonly tags: ReadonlyArray<Record<string, unknown>>
  readonly paths: Readonly<Record<string, Record<string, unknown>>>
  readonly components: Readonly<Record<string, unknown>>
}

export const endpoints = [
  "GET /v1/health",
  "GET /v1/info",
  "GET /v1/openapi.json",
  "GET /v1/update",
  "POST /v1/update/apply",
  "POST /v1/shutdown",
  "GET /v1/capabilities",
  "POST /v1/auth/pairing-token",
  "GET /v1/projects",
  "POST /v1/projects",
  "PATCH /v1/projects/:id",
  "DELETE /v1/projects/:id",
  "GET /v1/projects/:id/worktrees",
  "POST /v1/projects/:id/worktrees",
  "GET /v1/harnesses",
  "POST /v1/harnesses/rescan",
  "POST /v1/harnesses/auth/refresh",
  "GET /v1/harnesses/:id/agent-sessions",
  "PATCH /v1/harnesses/:id",
  "GET /v1/harnesses/:id/accounts",
  "POST /v1/harnesses/:id/accounts",
  "PATCH /v1/harnesses/:id/accounts/:accountId",
  "DELETE /v1/harnesses/:id/accounts/:accountId",
  "POST /v1/harnesses/:id/accounts/:accountId/activate",
  "POST /v1/harnesses/:id/accounts/:accountId/auth/probe",
  "POST /v1/harnesses/:id/accounts/:accountId/login",
  "DELETE /v1/harnesses/:id/accounts/:accountId/login/:flowId",
  "POST /v1/harnesses/:id/accounts/:accountId/logout",
  "GET /v1/sessions",
  "POST /v1/sessions",
  "GET /v1/sessions/:id",
  "GET /v1/sessions/:id/branch-diff",
  "PATCH /v1/sessions/:id",
  "DELETE /v1/sessions/:id",
  "POST /v1/sessions/:id/connect",
  "GET /v1/sessions/:id/transcript",
  "GET /v1/sessions/:id/transcript/:itemId/details",
  "GET /v1/sessions/:id/events",
  "GET /v1/sessions/:id/events/socket",
  "GET /v1/sessions/:id/queue",
  "PATCH /v1/sessions/:id/queue/:queueId",
  "DELETE /v1/sessions/:id/queue/:queueId",
  "POST /v1/sessions/:id/prompt",
  "POST /v1/sessions/:id/cancel",
  "POST /v1/sessions/:id/mode",
  "POST /v1/sessions/:id/config",
  "POST /v1/sessions/:id/goal",
  "DELETE /v1/sessions/:id/goal",
  "POST /v1/sessions/:id/questions/:questionId/answer",
  "POST /v1/files",
  "GET /v1/files/:id",
  "GET /v1/events",
  "GET /v1/events/socket",
  "POST /v1/terminals",
  "DELETE /v1/terminals/session/:sessionId",
  "GET /v1/terminals/:id/socket"
] as const

type Endpoint = (typeof endpoints)[number]
type JsonObject = Record<string, unknown>

const jsonSchema = (schema: Schema.Constraint): JsonObject => {
  const document = Schema.toJsonSchemaDocument(schema, {
    additionalProperties: false,
    generateDescriptions: true
  })
  return Object.keys(document.definitions).length === 0
    ? document.schema
    : { ...document.schema, $defs: document.definitions }
}

const arrayOf = (schema: Schema.Constraint): Schema.Constraint => Schema.Array(schema)
const nullable = (schema: Schema.Constraint): Schema.Constraint => Schema.NullOr(schema)

const requestSchemas = (): Partial<Record<Endpoint, Schema.Constraint>> => ({
  "POST /v1/projects": CreateProjectRequest,
  "PATCH /v1/projects/:id": UpdateProjectRequest,
  "POST /v1/projects/:id/worktrees": CreateWorktreeRequest,
  "PATCH /v1/harnesses/:id": UpdateHarnessRequest,
  "POST /v1/harnesses/:id/accounts": CreateHarnessAccountRequest,
  "PATCH /v1/harnesses/:id/accounts/:accountId": UpdateHarnessAccountRequest,
  "POST /v1/harnesses/:id/accounts/:accountId/login": StartHarnessLoginRequest,
  "POST /v1/sessions": CreateSessionRequest,
  "PATCH /v1/sessions/:id": UpdateSessionRequest,
  "PATCH /v1/sessions/:id/queue/:queueId": UpdateQueuedPromptRequest,
  "POST /v1/sessions/:id/prompt": PromptRequest,
  "POST /v1/sessions/:id/cancel": CancelRequest,
  "POST /v1/sessions/:id/mode": SetModeRequest,
  "POST /v1/sessions/:id/config": SetConfigRequest,
  "POST /v1/sessions/:id/goal": SetGoalRequest,
  "POST /v1/sessions/:id/questions/:questionId/answer": SetQuestionAnswerRequest,
  "POST /v1/terminals": TerminalCreateRequest
})

const responseSchemas = (): Partial<Record<Endpoint, Schema.Constraint>> => ({
  "GET /v1/health": HealthResponse,
  "GET /v1/info": ServerInfo,
  "GET /v1/update": UpdateInfo,
  "GET /v1/capabilities": ServerCapabilities,
  "POST /v1/auth/pairing-token": PairingTokenResponse,
  "GET /v1/projects": arrayOf(Project),
  "POST /v1/projects": Project,
  "PATCH /v1/projects/:id": Project,
  "GET /v1/projects/:id/worktrees": arrayOf(Worktree),
  "POST /v1/projects/:id/worktrees": Worktree,
  "GET /v1/harnesses": arrayOf(Harness),
  "POST /v1/harnesses/rescan": arrayOf(Harness),
  "POST /v1/harnesses/auth/refresh": arrayOf(Harness),
  "GET /v1/harnesses/:id/agent-sessions": arrayOf(AgentSessionSummary),
  "PATCH /v1/harnesses/:id": Harness,
  "GET /v1/harnesses/:id/accounts": arrayOf(HarnessAccount),
  "POST /v1/harnesses/:id/accounts": HarnessAccount,
  "PATCH /v1/harnesses/:id/accounts/:accountId": HarnessAccount,
  "POST /v1/harnesses/:id/accounts/:accountId/activate": arrayOf(HarnessAccount),
  "POST /v1/harnesses/:id/accounts/:accountId/auth/probe": HarnessAccount,
  "POST /v1/harnesses/:id/accounts/:accountId/login": HarnessAuthFlow,
  "POST /v1/harnesses/:id/accounts/:accountId/logout": HarnessAccount,
  "GET /v1/sessions": arrayOf(SessionSummary),
  "POST /v1/sessions": SessionSummary,
  "GET /v1/sessions/:id": SessionDetail,
  "GET /v1/sessions/:id/branch-diff": nullable(BranchDiffTotals),
  "PATCH /v1/sessions/:id": SessionSummary,
  "POST /v1/sessions/:id/connect": Schema.Struct({ agentSessionId: Schema.String }),
  "GET /v1/sessions/:id/transcript": TranscriptPage,
  "GET /v1/sessions/:id/transcript/:itemId/details": TranscriptItemDetails,
  "GET /v1/sessions/:id/events": arrayOf(EventEnvelope),
  "GET /v1/sessions/:id/queue": arrayOf(PromptQueueItem),
  "PATCH /v1/sessions/:id/queue/:queueId": PromptQueueItem,
  "POST /v1/sessions/:id/prompt": PromptAcceptedResponse,
  "POST /v1/sessions/:id/cancel": Schema.Struct({ cancelled: Schema.Boolean }),
  "POST /v1/sessions/:id/mode": Schema.Struct({ modeId: Schema.String }),
  "POST /v1/sessions/:id/config": Schema.Struct({ configId: Schema.String }),
  "POST /v1/sessions/:id/goal": SessionGoal,
  "POST /v1/sessions/:id/questions/:questionId/answer": Schema.Struct({
    outcome: Schema.Literals(["answered", "cancelled"]),
    questionId: Schema.String
  }),
  "POST /v1/files": FileMetadata,
  "GET /v1/events": EventEnvelope,
  "POST /v1/terminals": TerminalCreateResponse,
  "DELETE /v1/terminals/session/:sessionId": Schema.Struct({ closed: Schema.Boolean })
})

const summaries: Partial<Record<Endpoint, string>> = {
  "GET /v1/health": "Check server health",
  "GET /v1/info": "Get server information",
  "GET /v1/openapi.json": "Get the OpenAPI document",
  "POST /v1/auth/pairing-token": "Issue a pairing token",
  "GET /v1/events": "Stream global events with SSE",
  "GET /v1/events/socket": "Open the global event WebSocket",
  "GET /v1/sessions/:id/events/socket": "Open a session event WebSocket",
  "GET /v1/terminals/:id/socket": "Attach to a terminal WebSocket"
}

const noContent = new Set<Endpoint>([
  "DELETE /v1/projects/:id",
  "DELETE /v1/harnesses/:id/accounts/:accountId",
  "DELETE /v1/harnesses/:id/accounts/:accountId/login/:flowId",
  "DELETE /v1/sessions/:id",
  "DELETE /v1/sessions/:id/queue/:queueId",
  "DELETE /v1/sessions/:id/goal"
])

const created = new Set<Endpoint>([
  "POST /v1/auth/pairing-token",
  "POST /v1/projects",
  "POST /v1/projects/:id/worktrees",
  "POST /v1/harnesses/:id/accounts",
  "POST /v1/harnesses/:id/accounts/:accountId/login",
  "POST /v1/sessions",
  "POST /v1/files",
  "POST /v1/terminals"
])

const accepted = new Set<Endpoint>([
  "POST /v1/update/apply",
  "POST /v1/shutdown",
  "POST /v1/sessions/:id/prompt",
  "POST /v1/sessions/:id/cancel",
  "POST /v1/sessions/:id/mode",
  "POST /v1/sessions/:id/config",
  "POST /v1/sessions/:id/goal",
  "POST /v1/sessions/:id/questions/:questionId/answer"
])

const websocketEndpoints = new Set<Endpoint>([
  "GET /v1/events/socket",
  "GET /v1/sessions/:id/events/socket",
  "GET /v1/terminals/:id/socket"
])

const tagFor = (path: string): string => {
  if (path.includes("/auth/")) return "Authentication"
  if (path.includes("/projects")) return "Projects"
  if (path.includes("/harnesses")) return "Harnesses"
  if (path.includes("/sessions")) return "Sessions"
  if (path.includes("/files")) return "Files"
  if (path.includes("/events")) return "Events"
  if (path.includes("/terminals")) return "Terminals"
  if (path.includes("/update")) return "Updates"
  return "Server"
}

const titleCase = (value: string): string =>
  value
    .replace(/[:/.{}-]+/g, " ")
    .trim()
    .split(/\s+/)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")

const operationIdFor = (method: string, path: string): string => {
  const words = path
    .replace(/^\/v1\//, "")
    .replace(/\.json$/, "")
    .split("/")
    .filter((part) => part.length > 0)
    .map((part) => part.replace(/^:/, "by-"))
  return [method.toLowerCase(), ...words].join("-")
}

const pathParameters = (path: string): ReadonlyArray<JsonObject> =>
  [...path.matchAll(/:([A-Za-z][A-Za-z0-9]*)/g)].map((match) => ({
    name: match[1],
    in: "path",
    required: true,
    schema: { type: "string" }
  }))

const queryParameters = (endpoint: Endpoint): ReadonlyArray<JsonObject> => {
  if (endpoint === "GET /v1/capabilities") {
    return [{ name: "cwd", in: "query", schema: { type: "string" } }]
  }
  if (endpoint === "GET /v1/sessions/:id/transcript") {
    return [
      { name: "before", in: "query", schema: { type: "integer", minimum: 0 } },
      { name: "limit", in: "query", schema: { type: "integer", minimum: 1, default: 32 } }
    ]
  }
  if (endpoint === "POST /v1/files") {
    return [{ name: "name", in: "query", schema: { type: "string", default: "attachment" } }]
  }
  if (endpoint === "GET /v1/terminals/:id/socket") {
    return [{ name: "lastOutputSeq", in: "query", schema: { type: "integer", minimum: 0 } }]
  }
  if (endpoint === "GET /v1/events/socket" || endpoint === "GET /v1/sessions/:id/events/socket") {
    return [{ name: "since", in: "query", schema: { type: "integer", minimum: 0 } }]
  }
  if (endpoint === "GET /v1/events") {
    return [{ name: "since", in: "query", schema: { type: "integer", minimum: 0 } }]
  }
  return []
}

const makeOperation = (
  endpoint: Endpoint,
  requests: Partial<Record<Endpoint, Schema.Constraint>>,
  responses: Partial<Record<Endpoint, Schema.Constraint>>
): JsonObject => {
  const [method, rawPath] = endpoint.split(" ") as [string, string]
  const requestSchema = requests[endpoint]
  const responseSchema = responses[endpoint]
  const parameters = [...pathParameters(rawPath), ...queryParameters(endpoint)]
  const isWebSocket = websocketEndpoints.has(endpoint)
  const successStatus = noContent.has(endpoint)
    ? "204"
    : isWebSocket
      ? "101"
      : created.has(endpoint)
        ? "201"
        : accepted.has(endpoint)
          ? "202"
          : "200"
  const successResponse: JsonObject = {
    description: isWebSocket ? "Switching Protocols" : "Success"
  }

  if (responseSchema !== undefined && !isWebSocket) {
    successResponse.content = {
      [endpoint === "GET /v1/events" ? "text/event-stream" : "application/json"]: {
        schema: jsonSchema(responseSchema)
      }
    }
  }
  if (endpoint === "GET /v1/files/:id") {
    successResponse.content = {
      "application/octet-stream": { schema: { type: "string", format: "binary" } }
    }
  }

  const operation: JsonObject = {
    operationId: operationIdFor(method, rawPath),
    tags: [tagFor(rawPath)],
    summary:
      summaries[endpoint] ?? `${titleCase(method)} ${titleCase(rawPath.replace(/^\/v1\/?/, ""))}`,
    description:
      endpoint === "POST /v1/auth/pairing-token"
        ? "Issue a bearer token from a trusted localhost connection, then use it to authenticate remote requests."
        : isWebSocket
          ? "Upgrade to WebSocket. See the real-time and terminal protocol guides for replay and frame semantics."
          : undefined,
    security: endpoint === "GET /v1/health" ? [] : [{ bearerAuth: [] }],
    responses: {
      [successStatus]: successResponse,
      "401": { $ref: "#/components/responses/Unauthorized" },
      "422": { $ref: "#/components/responses/InvalidRequest" },
      "500": { $ref: "#/components/responses/ServerError" }
    }
  }
  if (parameters.length > 0) operation.parameters = parameters
  if (requestSchema !== undefined) {
    operation.requestBody = {
      required: true,
      content: { "application/json": { schema: jsonSchema(requestSchema) } }
    }
  }
  if (endpoint === "POST /v1/files") {
    operation.requestBody = {
      required: true,
      content: { "application/octet-stream": { schema: { type: "string", format: "binary" } } }
    }
  }
  if (endpoint === "GET /v1/events/socket" || endpoint === "GET /v1/sessions/:id/events/socket") {
    operation["x-websocket-server-message"] = jsonSchema(EventEnvelope)
  }
  if (endpoint === "GET /v1/terminals/:id/socket") {
    operation["x-websocket-client-message"] = jsonSchema(TerminalClientFrame)
    operation["x-websocket-server-message"] = jsonSchema(TerminalServerFrame)
  }
  return operation
}

export const makeOpenApiDocument = (version: string): HerdManOpenApi => {
  const requests = requestSchemas()
  const responses = responseSchemas()
  const paths: Record<string, Record<string, unknown>> = {}

  for (const endpoint of endpoints) {
    const [method, rawPath] = endpoint.split(" ") as [string, string]
    const path = rawPath.replace(/:([A-Za-z][A-Za-z0-9]*)/g, "{$1}")
    paths[path] ??= {}
    paths[path]![method.toLowerCase()] = makeOperation(endpoint, requests, responses)
  }

  const errorSchema = {
    type: "object",
    required: ["error"],
    properties: { error: { type: "string" } },
    additionalProperties: false
  }
  const errorResponse = (description: string): JsonObject => ({
    description,
    content: { "application/json": { schema: errorSchema } }
  })

  return {
    openapi: "3.1.0",
    info: {
      title: "HerdMan Server API",
      version,
      description:
        "Experimental public API for running coding-agent sessions, projects, files, events, and terminals on a HerdMan server."
    },
    servers: [
      {
        url: "http://127.0.0.1:49361",
        description: "Default local server"
      }
    ],
    tags: [
      "Server",
      "Authentication",
      "Updates",
      "Projects",
      "Harnesses",
      "Sessions",
      "Files",
      "Events",
      "Terminals"
    ].map((name) => ({ name })),
    paths,
    components: {
      securitySchemes: {
        bearerAuth: {
          type: "http",
          scheme: "bearer",
          bearerFormat: "HerdMan pairing token"
        }
      },
      responses: {
        Unauthorized: errorResponse("A valid bearer token is required for non-local requests."),
        InvalidRequest: errorResponse("The request failed validation."),
        ServerError: errorResponse("The server could not complete the request.")
      }
    }
  }
}
