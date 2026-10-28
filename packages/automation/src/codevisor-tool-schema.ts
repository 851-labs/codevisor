import { jsonSchema } from "@codevisor/api"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"

import type { CodevisorApiToolSpec, JsonSchema } from "./codevisor-api-tools.js"
import { isRecord, isStringArray, recordOrEmpty, type UnknownRecord } from "./unknown-values.js"

export const pathParameterNames = (path: string): ReadonlyArray<string> =>
  [...path.matchAll(/:([A-Za-z][A-Za-z0-9]*)/g)].map((match) => match[1]!)

const idArgumentNames = {
  agents: "agentId",
  projects: "projectId",
  workspaces: "workspaceId",
  sessions: "agentId",
  mcps: "mcpId",
  harnesses: "harnessId",
  "native-mcps": "removalId",
  files: "fileId",
  sandboxes: "sandboxId",
  "sandbox-accounts": "accountId",
  "sandbox-profiles": "profileId"
} as const

const isIdResource = (segment: string | undefined): segment is keyof typeof idArgumentNames =>
  segment !== undefined && Object.hasOwn(idArgumentNames, segment)

export const callerDefault = (
  spec: CodevisorApiToolSpec,
  parameterName: string
): "session" | "project" | undefined => {
  if (spec.name.startsWith("agents.")) return undefined
  if (parameterName === "sessionId") return "session"
  if (parameterName !== "id") return undefined
  if (spec.path.startsWith("/v1/sessions/:id")) return "session"
  if (spec.path.startsWith("/v1/projects/:id")) return "project"
  return undefined
}

export const pathArgumentName = (spec: CodevisorApiToolSpec, parameterName: string): string => {
  const resource = spec.path.split("/")[2]
  if (parameterName !== "id" || !isIdResource(resource)) return parameterName
  return idArgumentNames[resource]
}

const callerDefaultDescriptions = {
  session: "Agent id. Defaults to the calling agent.",
  project: "Project id. Defaults to the calling project.",
  none: undefined
} as const

export const schemaProperties = (schema: JsonSchema): Record<string, object> =>
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
    const defaulted = callerDefault(spec, parameterName)
    properties[argumentName] = {
      type: "string",
      description: callerDefaultDescriptions[defaulted ?? "none"]
    }
    if (defaulted === undefined) required.add(argumentName)
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
      for (const name of isStringArray(schema.required) ? schema.required : []) required.add(name)
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
