import { randomUUID } from "node:crypto"

import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"
import { Schema } from "effect"

import type { AutomationProviderContext, AutomationToolProvider } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { CodeExecutionToolError } from "./code-executor.js"
import {
  CODEVISOR_API_TOOLS,
  objectSchema,
  type CodevisorApiToolSpec,
  type JsonSchema
} from "./codevisor-api-tools.js"

const pathParameterNames = (path: string): ReadonlyArray<string> =>
  [...path.matchAll(/:([A-Za-z][A-Za-z0-9]*)/g)].map((match) => match[1]!)

const idArgumentNames = {
  projects: "projectId",
  workspaces: "workspaceId",
  sessions: "sessionId",
  mcps: "mcpId",
  harnesses: "harnessId",
  "native-mcps": "removalId",
  files: "fileId"
} as const

const pathArgumentName = (spec: CodevisorApiToolSpec, parameterName: string): string => {
  if (parameterName !== "id") return parameterName
  return idArgumentNames[spec.path.split("/")[2] as keyof typeof idArgumentNames]
}

const contextDefault = (
  spec: CodevisorApiToolSpec,
  name: string,
  context: AutomationProviderContext
): string | undefined => {
  if ((name === "id" && spec.path.startsWith("/v1/sessions/:id")) || name === "sessionId") {
    return context.sessionId
  }
  if (name === "id" && spec.path.startsWith("/v1/projects/:id")) {
    return context.projectId
  }
  return undefined
}

const toolInputSchema = (spec: CodevisorApiToolSpec): JsonSchema => {
  const properties: Record<string, unknown> = {}
  const required = new Set<string>()
  let definitions: unknown

  for (const parameterName of pathParameterNames(spec.path)) {
    const argumentName = pathArgumentName(spec, parameterName)
    properties[argumentName] = {
      type: "string",
      description:
        parameterName === "id" && spec.path.startsWith("/v1/sessions/:id")
          ? "Session id. Defaults to the calling session."
          : parameterName === "id" && spec.path.startsWith("/v1/projects/:id")
            ? "Project id. Defaults to the calling project."
            : undefined
    }
    if (
      !(
        parameterName === "sessionId" ||
        (parameterName === "id" &&
          (spec.path.startsWith("/v1/sessions/:id") || spec.path.startsWith("/v1/projects/:id")))
      )
    ) {
      required.add(argumentName)
    }
  }

  for (const parameter of spec.query ?? []) {
    properties[parameter.name] = {
      ...parameter.schema,
      ...(parameter.description === undefined ? {} : { description: parameter.description })
    }
  }

  if (spec.name === "files.upload") {
    properties.dataBase64 = {
      type: "string",
      description: "File bytes encoded as base64."
    }
    required.add("dataBase64")
  } else if (spec.body !== undefined) {
    const schema = objectSchema(spec.body)
    if (spec.wrappedBody === true) {
      properties.body = schema
      required.add("body")
    } else {
      Object.assign(properties, schema.properties as Record<string, unknown>)
      for (const name of (schema.required as ReadonlyArray<string> | undefined) ?? []) {
        if (!(spec.name === "sessions.create" && name === "projectId")) required.add(name)
      }
      definitions = schema.$defs
    }
  }

  if (spec.confirm === true) {
    properties.confirm = {
      type: "boolean",
      description:
        "Must only be set true after showing the user exactly what this call will do " +
        "(the discovered manifest and verbatim commands) and receiving their explicit approval."
    }
    required.add("confirm")
  }

  return {
    type: "object",
    properties,
    ...(required.size === 0 ? {} : { required: [...required] }),
    additionalProperties: false,
    ...(definitions === undefined ? {} : { $defs: definitions })
  }
}

const tools: ReadonlyArray<Tool> = [
  {
    name: "context.current",
    description:
      "Return the calling Codevisor session: sessionId, projectId, workspaceId, worktreeName (its git worktree, absent for the project folder), parentSessionId (the agent that created this one, if any), the machine it runs on, and clientId (the app window that sent the current prompt, absent for automations and agent-sent prompts).",
    inputSchema: { type: "object", properties: {}, additionalProperties: false }
  },
  ...CODEVISOR_API_TOOLS.map((spec): Tool => ({
    name: spec.name,
    description: spec.description,
    inputSchema: toolInputSchema(spec) as Tool["inputSchema"]
  }))
]

const loopbackBaseUrl = (value: string): URL => {
  const url = new URL(value)
  if (url.hostname === "0.0.0.0" || url.hostname === "::" || url.hostname === "[::]") {
    url.hostname = "127.0.0.1"
  }
  return url
}

const bodyPropertyNames = (schema: Schema.Constraint): ReadonlyArray<string> =>
  Object.keys(objectSchema(schema).properties as Record<string, unknown>)

const responseError = async (spec: CodevisorApiToolSpec, response: Response): Promise<Error> => {
  const text = await response.text()
  let detail = text.trim()
  let typed: { readonly message?: unknown; readonly code?: unknown; readonly details?: unknown } =
    {}
  try {
    const parsed = JSON.parse(text) as { readonly error?: unknown; readonly code?: unknown }
    // Typed failures arrive as `{ error, code, details }` or
    // `{ error: { message, code, details } }`.
    typed =
      typeof parsed.error === "object" && parsed.error !== null
        ? (parsed.error as typeof typed)
        : { ...parsed, message: parsed.error }
    if (typeof typed.message === "string") detail = typed.message
  } catch {
    // Plain-text failures retain the response body.
  }
  const code = typeof typed.code === "string" ? typed.code : undefined
  const details =
    typeof typed.details === "object" && typed.details !== null
      ? (typed.details as Readonly<Record<string, unknown>>)
      : undefined
  const message = `${spec.name} failed (${response.status}${response.statusText.length === 0 ? "" : ` ${response.statusText}`}): ${detail || "Codevisor request failed"}`
  // Coded failures (an unavailable client, say) reach sandbox code intact so
  // it can catch them by class; everything else stays a plain error.
  return code === undefined
    ? new Error(message)
    : new CodeExecutionToolError(detail, { code, ...(details === undefined ? {} : { details }) })
}

/// Fills the defaults an agent-created chat needs: the calling project, and a
/// fresh workspace. Native sidebars list workspaces, so a chat created without
/// one runs but never appears to the user. Native clients may create
/// workspace-less rows and attach them later; agents have no such follow-up.
const sessionCreatePayload = (
  payload: Readonly<Record<string, unknown>>,
  context: AutomationProviderContext
): Readonly<Record<string, unknown>> => ({
  ...payload,
  ...("projectId" in payload || context.projectId === undefined
    ? {}
    : { projectId: context.projectId }),
  // Sessions an agent starts belong to it, so it can find them again later.
  ...("parentSessionId" in payload || context.sessionId === undefined
    ? {}
    : { parentSessionId: context.sessionId }),
  ...("workspaceId" in payload ? {} : { workspaceId: randomUUID() })
})

const invokeApiTool = async (
  getBaseUrl: () => string,
  getBearerToken: () => Promise<string>,
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: Readonly<Record<string, unknown>>
): Promise<CallToolResult> => {
  // The consent gate never reaches the server: `confirm` is not a body or
  // query property, so it is dropped from the request after this check.
  if (spec.confirm === true && args.confirm !== true) {
    throw new Error(
      `${spec.name} requires confirm: true — show the user what this call will run ` +
        "(via the matching discover tool) and get their explicit approval first"
    )
  }
  let path = spec.path
  for (const parameterName of pathParameterNames(spec.path)) {
    const argumentName = pathArgumentName(spec, parameterName)
    const value = args[argumentName] ?? contextDefault(spec, parameterName, context)
    if (typeof value !== "string" || value.length === 0) {
      throw new Error(`${spec.name} requires ${argumentName}`)
    }
    path = path.replace(`:${parameterName}`, encodeURIComponent(value))
  }

  const url = new URL(path, loopbackBaseUrl(getBaseUrl()))
  for (const parameter of spec.query ?? []) {
    const value = args[parameter.name]
    if (value === undefined) continue
    // The update routes use refresh=1, while all other booleans use the
    // conventional true/false representation.
    url.searchParams.set(
      parameter.name,
      spec.name === "server.update_status" && parameter.name === "refresh" && value === true
        ? "1"
        : String(value)
    )
  }

  const headers = new Headers()
  headers.set("authorization", `Bearer ${await getBearerToken()}`)
  let body: BodyInit | undefined
  if (spec.name === "files.upload") {
    const encoded = args.dataBase64
    if (typeof encoded !== "string") throw new Error("files.upload requires dataBase64")
    body = Buffer.from(encoded, "base64")
    headers.set(
      "content-type",
      typeof args.mimeType === "string" ? args.mimeType : "application/octet-stream"
    )
    // mimeType is represented as a query-like tool argument for schema
    // ergonomics, but the server consumes it from Content-Type.
    url.searchParams.delete("mimeType")
  } else if (spec.body !== undefined) {
    const fields = (): Readonly<Record<string, unknown>> =>
      Object.fromEntries(
        bodyPropertyNames(spec.body!)
          .filter((name) => args[name] !== undefined)
          .map((name) => [name, args[name]])
      )
    body = JSON.stringify(
      spec.wrappedBody === true
        ? args.body
        : spec.name === "sessions.create"
          ? sessionCreatePayload(fields(), context)
          : fields()
    )
    headers.set("content-type", "application/json")
  }

  const response = await fetch(url, {
    method: spec.method,
    headers,
    ...(body === undefined ? {} : { body })
  })
  if (!response.ok) throw await responseError(spec, response)

  if (spec.response === "binary") {
    const bytes = Buffer.from(await response.arrayBuffer())
    return {
      content: [
        {
          type: "resource",
          resource: {
            uri: url.toString(),
            mimeType: response.headers.get("content-type") ?? "application/octet-stream",
            blob: bytes.toString("base64")
          }
        }
      ]
    }
  }

  const text = await response.text()
  if (text.length === 0) {
    return textToolResult(JSON.stringify({ ok: true, status: response.status }))
  }
  const contentType = response.headers.get("content-type") ?? ""
  if (contentType.includes("application/json")) {
    return textToolResult(JSON.stringify(JSON.parse(text) as unknown))
  }
  return textToolResult(text)
}

/// What `context.current` reports beyond the session and project ids. The
/// gateway owns these facts (machine identity, turn origin, parent link).
export interface CodevisorCurrentContext {
  readonly workspaceId?: string
  /// The git worktree the calling session runs in; absent for the project folder.
  readonly worktreeName?: string
  readonly parentSessionId?: string
  readonly machine?: { readonly id: string; readonly name: string }
  readonly clientId?: string
}

export interface CodevisorProviderOptions {
  readonly currentContext?: (context: AutomationProviderContext) => Promise<CodevisorCurrentContext>
}

export const makeCodevisorProvider = (
  getBaseUrl: () => string,
  getBearerToken: () => Promise<string>,
  options: CodevisorProviderOptions = {}
): AutomationToolProvider => ({
  id: "codevisor",
  tools,
  invoke: async (context, toolName, args) => {
    if (toolName === "context.current") {
      const extra = (await options.currentContext?.(context)) ?? {}
      return textToolResult(
        JSON.stringify({
          sessionId: context.sessionId,
          ...(context.projectId === undefined ? {} : { projectId: context.projectId }),
          ...(extra.workspaceId === undefined ? {} : { workspaceId: extra.workspaceId }),
          ...(extra.worktreeName === undefined ? {} : { worktreeName: extra.worktreeName }),
          ...(extra.parentSessionId === undefined
            ? {}
            : { parentSessionId: extra.parentSessionId }),
          ...(extra.machine === undefined ? {} : { machine: extra.machine }),
          ...(extra.clientId === undefined ? {} : { clientId: extra.clientId })
        })
      )
    }
    const spec = CODEVISOR_API_TOOLS.find((candidate) => candidate.name === toolName)
    if (spec === undefined) throw new Error(`Unknown Codevisor tool: ${toolName}`)
    return invokeApiTool(getBaseUrl, getBearerToken, spec, context, args)
  },
  closeSession: async () => undefined,
  close: async () => undefined
})

export const codevisorTools = tools
