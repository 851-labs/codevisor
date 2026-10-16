import { Schema } from "effect"

export { jsonSchema as objectSchema } from "@codevisor/api"

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

export const integerQuery = (name: string, description: string): QueryParameter => ({
  name,
  schema: { type: "integer", minimum: 0 },
  description
})

export const enabledBody = Schema.Struct({ enabled: Schema.Boolean })
export const cloudConnectBody = Schema.Struct({
  serverUrl: Schema.optional(Schema.String),
  sessionToken: Schema.optional(Schema.String),
  inviteCode: Schema.optional(Schema.String),
  machineName: Schema.optional(Schema.String)
})
export const harnessInstallBody = Schema.Struct({ methodId: Schema.optional(Schema.String) })

export const apiTool = (
  name: string,
  description: string,
  method: HttpMethod,
  path: string,
  options: Omit<CodevisorApiToolSpec, "description" | "method" | "name" | "path"> = {}
): CodevisorApiToolSpec => ({ name, description, method, path, ...options })
