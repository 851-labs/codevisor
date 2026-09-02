import type { Schema } from "effect"
import { EventEnvelope, TerminalClientFrame, TerminalServerFrame } from "./index.js"
import {
  accepted,
  created,
  endpoints,
  noContent,
  summaries,
  websocketEndpoints,
  type Endpoint
} from "./openapi-endpoints.js"
import { jsonSchema, requestSchemas, responseSchemas, type JsonObject } from "./openapi-schemas.js"

export { endpoints } from "./openapi-endpoints.js"

export interface CodevisorOpenApi {
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

const tagFor = (path: string): string => {
  if (path.includes("/auth/")) return "Authentication"
  if (path.includes("/mcps")) return "MCP servers"
  if (path.includes("/projects")) return "Projects"
  if (path.includes("/workspace")) return "Workspaces"
  if (path.includes("/harnesses")) return "Harnesses"
  if (path.includes("/plugins")) return "Plugins"
  if (path.includes("/skills")) return "Skills"
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
    return [
      { name: "cwd", in: "query", schema: { type: "string" } },
      { name: "harnessId", in: "query", schema: { type: "string" } }
    ]
  }
  if (endpoint === "GET /v1/plugins/registry") {
    return [{ name: "q", in: "query", schema: { type: "string" } }]
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
  if (
    endpoint === "GET /v1/plugins/:pluginId/icon" ||
    endpoint === "GET /v1/plugins/:pluginId/panes/:paneType/icon"
  ) {
    successResponse.content = {
      "image/png": { schema: { type: "string", format: "binary" } }
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
    security:
      endpoint === "GET /v1/health" || endpoint === "GET /v1/discovery" ? [] : [{ bearerAuth: [] }],
    responses: {
      [successStatus]: successResponse,
      "400": { $ref: "#/components/responses/BadRequest" },
      "401": { $ref: "#/components/responses/Unauthorized" },
      "404": { $ref: "#/components/responses/NotFound" },
      "409": { $ref: "#/components/responses/Conflict" },
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

export const makeOpenApiDocument = (version: string): CodevisorOpenApi => {
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
      title: "Codevisor Server API",
      version,
      description:
        "Experimental public API for projects, coding-agent sessions, extensions, files, events, and terminals on a Codevisor server."
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
      "Workspaces",
      "Harnesses",
      "Plugins",
      "MCP servers",
      "Skills",
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
          bearerFormat: "Codevisor pairing token"
        }
      },
      responses: {
        BadRequest: errorResponse(
          "The JSON body is malformed or does not match the request schema."
        ),
        Unauthorized: errorResponse("A valid bearer token is required for non-local requests."),
        NotFound: errorResponse("The requested resource does not exist."),
        Conflict: errorResponse("The request conflicts with the resource's current state."),
        InvalidRequest: errorResponse("The request is well formed but cannot be applied."),
        ServerError: errorResponse("The server could not complete the request.")
      }
    }
  }
}
