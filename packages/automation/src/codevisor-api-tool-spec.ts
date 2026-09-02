import { Schema } from "effect"

/// The tool-spec shape and the builders every Codevisor API tool entry uses.

export type JsonSchema = Record<string, unknown>
export type HttpMethod = "DELETE" | "GET" | "PATCH" | "POST" | "PUT"

export interface QueryParameter {
  readonly name: string
  readonly schema: JsonSchema
  readonly description?: string | undefined
}

export interface CodevisorApiToolSpec {
  readonly name: string
  readonly description: string
  readonly method: HttpMethod
  readonly path: string
  readonly body?: Schema.Constraint | undefined
  readonly wrappedBody?: boolean | undefined
  readonly query?: ReadonlyArray<QueryParameter> | undefined
  readonly response?: "binary" | undefined
  /// Consent gate: the tool grows a required boolean `confirm` argument that
  /// is never forwarded to the server, and the provider refuses to send the
  /// request unless it is exactly `true`. Used where an agent action runs
  /// commands on the user's machine (e.g. plugin install) and the agent must
  /// first show the user what will happen and receive explicit approval.
  readonly confirm?: boolean | undefined
}

export const stringQuery = (name: string, description?: string): QueryParameter => ({
  name,
  schema: { type: "string" },
  ...(description === undefined ? {} : { description })
})

export const booleanQuery = (name: string, description?: string): QueryParameter => ({
  name,
  schema: { type: "boolean" },
  ...(description === undefined ? {} : { description })
})

export const integerQuery = (name: string, description?: string): QueryParameter => ({
  name,
  schema: { type: "integer", minimum: 0 },
  ...(description === undefined ? {} : { description })
})

export const objectSchema = (schema: Schema.Constraint): JsonSchema => {
  const document = Schema.toJsonSchemaDocument(schema, {
    additionalProperties: false,
    generateDescriptions: true
  })
  return { ...document.schema, $defs: document.definitions }
}

export const enabledBody = Schema.Struct({ enabled: Schema.Boolean })
export const cloudConnectBody = Schema.Struct({
  serverUrl: Schema.String,
  sessionToken: Schema.String
})
export const harnessInstallBody = Schema.Struct({ methodId: Schema.optional(Schema.String) })

export const apiTool = (
  name: string,
  description: string,
  method: HttpMethod,
  path: string,
  options: Omit<CodevisorApiToolSpec, "description" | "method" | "name" | "path"> = {}
): CodevisorApiToolSpec => ({ name, description, method, path, ...options })
