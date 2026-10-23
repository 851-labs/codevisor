import { REMOTE_PARENT_HEADER, jsonSchema } from "@codevisor/api"
import { Schema } from "effect"

import type { AutomationProviderContext } from "./automation-provider.js"
import { isRemoteScope } from "./codevisor-agent-caller.js"
import type { QueryParameter } from "./codevisor-api-tool-spec.js"
import type { CodevisorApiToolSpec } from "./codevisor-api-tools.js"
import { callerDefault, pathArgumentName, pathParameterNames } from "./codevisor-tool-schema.js"
import { budgetedWaitPayload } from "./codevisor-wait-budget.js"
import { recordOrEmpty, type UnknownRecord } from "./unknown-values.js"

export interface RequestBody {
  readonly body?: BodyInit
  readonly contentType?: string
  readonly clampedToMs?: number | undefined
}

export const requestUrl = (
  getBaseUrl: () => string,
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: UnknownRecord
): URL => {
  const path = resolvedPath(spec, context, args)
  const url = new URL(path, loopbackBaseUrl(getBaseUrl()))
  return withQuery(url, spec, args)
}

export const bearerHeaders = (token: string, context: AutomationProviderContext): Headers => {
  const headers = new Headers()
  headers.set("authorization", `Bearer ${token}`)
  if (context.remoteParent !== undefined) headers.set(REMOTE_PARENT_HEADER, context.remoteParent)
  return headers
}

export const requestBody = (
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: UnknownRecord,
  url: URL
): RequestBody => {
  if (spec.name === "files.upload") {
    const upload = uploadBody(args)
    removeMimeTypeQuery(url)
    return upload
  }
  if (spec.body !== undefined) return jsonBody(spec, context, args)
  return {}
}

export const requestInit = (
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  headers: Headers,
  request: RequestBody
): RequestInit => {
  if (request.contentType !== undefined) headers.set("content-type", request.contentType)
  return {
    method: spec.method,
    headers,
    ...(request.body === undefined ? {} : { body: request.body }),
    ...(context.signal === undefined ? {} : { signal: context.signal })
  }
}

const resolvedPath = (
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: UnknownRecord
): string => {
  let path = spec.path
  for (const parameterName of pathParameterNames(spec.path)) {
    const value = pathValue(spec, parameterName, context, args)
    path = path.replace(`:${parameterName}`, encodeURIComponent(value))
  }
  return path
}

const pathValue = (
  spec: CodevisorApiToolSpec,
  parameterName: string,
  context: AutomationProviderContext,
  args: UnknownRecord
): string => {
  const argumentName = pathArgumentName(spec, parameterName)
  const value = args[argumentName] ?? contextDefault(spec, parameterName, context)
  if (!isPathValue(value)) throw new Error(`${spec.name} requires ${argumentName}`)
  return value
}

const isPathValue = (value: unknown): value is string =>
  typeof value === "string" && value.length !== 0

const contextDefault = (
  spec: CodevisorApiToolSpec,
  name: string,
  context: AutomationProviderContext
): string | undefined => {
  const defaulted = callerDefault(spec, name)
  if (defaulted === "session") return context.sessionId
  if (defaulted === "project") return context.projectId
  return undefined
}

export const loopbackBaseUrl = (value: string): URL => {
  const url = new URL(value)
  if (url.hostname === "0.0.0.0" || url.hostname === "::" || url.hostname === "[::]") {
    url.hostname = "127.0.0.1"
  }
  return url
}

const withQuery = (url: URL, spec: CodevisorApiToolSpec, args: UnknownRecord): URL => {
  for (const parameter of spec.query ?? []) {
    const value = args[parameter.name]
    if (value === undefined) continue
    url.searchParams.set(parameter.name, queryParameterValue(spec, parameter, value))
  }
  return url
}

const queryParameterValue = (
  spec: CodevisorApiToolSpec,
  parameter: QueryParameter,
  value: unknown
): string => {
  if (spec.name === "server.update_status" && parameter.name === "refresh" && value === true)
    return "1"
  if (typeof value === "string") return value
  return JSON.stringify(value)
}

const uploadBody = (args: UnknownRecord): RequestBody => {
  const encoded = args.dataBase64
  if (typeof encoded !== "string") throw new Error("files.upload requires dataBase64")
  const body = Buffer.from(encoded, "base64")
  const contentType = uploadContentType(args)
  return { body, contentType }
}

const removeMimeTypeQuery = (url: URL): void => {
  url.searchParams.delete("mimeType")
}

const uploadContentType = (args: UnknownRecord): string =>
  typeof args.mimeType === "string" ? args.mimeType : "application/octet-stream"

const jsonBody = (
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: UnknownRecord
): RequestBody => {
  const budgeted = budgetedWaitPayload(spec, bodyPayload(spec, context, args), context)
  return {
    clampedToMs: budgeted.clampedToMs,
    body: JSON.stringify(budgeted.payload),
    contentType: "application/json"
  }
}

const bodyPayload = (
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: UnknownRecord
): unknown => {
  if (spec.wrappedBody === true) return args.body
  const payload = definedArguments(args, bodyPropertyNames(spec.body!))
  if (spec.name === "agents.message") return { ...payload, fromSessionId: context.sessionId }
  if (spec.name === "agents.start") return startPayload(payload, context)
  return payload
}

const startPayload = (
  payload: UnknownRecord,
  context: AutomationProviderContext
): UnknownRecord => {
  if (isRemoteScope(context.sessionId))
    return { ...payload, remoteParentAgentId: context.sessionId }
  return { ...payload, callerAgentId: context.sessionId }
}

const definedArguments = (args: UnknownRecord, names: ReadonlyArray<string>): UnknownRecord =>
  Object.fromEntries(
    names.filter((name) => args[name] !== undefined).map((name) => [name, args[name]])
  )

const bodyPropertyNames = (schema: Schema.Constraint): ReadonlyArray<string> =>
  Object.keys(recordOrEmpty(jsonSchema(schema).properties))
