import { jsonSchema } from "@codevisor/api"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

import type { CodevisorApiToolSpec, JsonSchema } from "./codevisor-api-tools.js"
import { isRecord, isStringArray, recordOrEmpty, type UnknownRecord } from "./unknown-values.js"

export const pathParameterNames = (path: string): ReadonlyArray<string> =>
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

const isIdResource = (segment: string | undefined): segment is keyof typeof idArgumentNames =>
  segment !== undefined && Object.hasOwn(idArgumentNames, segment)

export const pathArgumentName = (spec: CodevisorApiToolSpec, parameterName: string): string => {
  const resource = spec.path.split("/")[2]
  if (parameterName !== "id" || !isIdResource(resource)) return parameterName
  return idArgumentNames[resource]
}

const schemaProperties = (schema: JsonSchema): Record<string, object> =>
  Object.fromEntries(
    Object.entries(recordOrEmpty(schema.properties)).filter(
      (entry): entry is [string, UnknownRecord] => isRecord(entry[1])
    )
  )

export const toolInputSchema = (spec: CodevisorApiToolSpec): Tool["inputSchema"] => {
  const properties: Record<string, object> = {}
  const required = new Set<string>()
  let definitions: unknown

  for (const parameterName of pathParameterNames(spec.path)) {
    const argumentName = pathArgumentName(spec, parameterName)
    let description: string | undefined
    if (parameterName === "id" && spec.path.startsWith("/v1/sessions/:id")) {
      description = "Session id. Defaults to the calling session."
    } else if (parameterName === "id" && spec.path.startsWith("/v1/projects/:id")) {
      description = "Project id. Defaults to the calling project."
    }
    properties[argumentName] = { type: "string", description }
    if (parameterName === "sessionId") continue
    if (
      parameterName === "id" &&
      (spec.path.startsWith("/v1/sessions/:id") || spec.path.startsWith("/v1/projects/:id"))
    ) {
      continue
    }
    required.add(argumentName)
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
    const schema = jsonSchema(spec.body)
    if (spec.wrappedBody === true) {
      properties.body = schema
      required.add("body")
    } else {
      Object.assign(properties, schemaProperties(schema))
      for (const name of isStringArray(schema.required) ? schema.required : []) {
        if (spec.name === "sessions.create" && name === "projectId") continue
        required.add(name)
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
