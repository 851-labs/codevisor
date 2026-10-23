import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"

import type { AutomationProviderContext, AutomationToolProvider } from "./automation-provider.js"
import { textToolResult } from "./automation-provider.js"
import { bearerHeaders, requestBody, requestInit, requestUrl } from "./codevisor-api-request.js"
import { resourceResult, responseError, textResult } from "./codevisor-api-response.js"
import { CODEVISOR_API_TOOLS, type CodevisorApiToolSpec } from "./codevisor-api-tools.js"
import { toolInputSchema } from "./codevisor-tool-schema.js"
import type { UnknownRecord } from "./unknown-values.js"

export {
  CODEVISOR_BOT_TOOL_NAMES,
  CODEVISOR_CONVERSATIONAL_BOT_TOOL_NAMES
} from "./codevisor-api-tools.js"

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
    inputSchema: toolInputSchema(spec)
  }))
]

const invokeApiTool = async (
  getBaseUrl: () => string,
  getBearerToken: () => Promise<string>,
  spec: CodevisorApiToolSpec,
  context: AutomationProviderContext,
  args: UnknownRecord
): Promise<CallToolResult> => {
  if (unconfirmed(spec, args)) throw confirmationRequired(spec)
  const url = requestUrl(getBaseUrl, spec, context, args)

  const headers = bearerHeaders(await getBearerToken(), context)
  const request = requestBody(spec, context, args, url)
  const response = await fetch(url, requestInit(spec, context, headers, request))
  if (!response.ok) throw await responseError(spec, response)

  if (spec.response === "binary") {
    const bytes = Buffer.from(await response.arrayBuffer())
    return resourceResult(url, response, bytes)
  }
  return textResult(response, await response.text(), request.clampedToMs)
}

const unconfirmed = (spec: CodevisorApiToolSpec, args: UnknownRecord): boolean =>
  spec.confirm === true && args.confirm !== true

const confirmationRequired = (spec: CodevisorApiToolSpec): Error =>
  new Error(
    `${spec.name} requires confirm: true — show the user what this call will run ` +
      "(via the matching discover tool) and get their explicit approval first"
  )

export interface CodevisorCurrentContext {
  readonly workspaceId?: string
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
