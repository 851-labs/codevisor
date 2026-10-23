import { jsonSchema } from "@codevisor/api"
import type { Tool } from "@modelcontextprotocol/sdk/types.js"
import type { Schema } from "effect"

import type { AutomationProviderContext } from "./automation-provider.js"
import type { CodevisorApi } from "./codevisor-api-client.js"
import { schemaProperties } from "./codevisor-tool-schema.js"

export interface AgentToolContext {
  readonly api: CodevisorApi
  readonly context: AutomationProviderContext
}

export interface AgentTool {
  readonly definition: Tool
  readonly run: (tool: AgentToolContext, args: unknown) => Promise<unknown>
}

export const agentTool = (
  name: string,
  description: string,
  input: Schema.Constraint,
  run: AgentTool["run"]
): AgentTool => ({ definition: { name, description, inputSchema: objectInputSchema(input) }, run })

const objectInputSchema = (input: Schema.Constraint): Tool["inputSchema"] => {
  const schema = jsonSchema(input)
  const required = Array.isArray(schema.required) ? schema.required : []
  return {
    type: "object",
    properties: schemaProperties(schema),
    ...(required.length === 0 ? {} : { required }),
    additionalProperties: false
  }
}
