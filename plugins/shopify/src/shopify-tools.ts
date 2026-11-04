import { errorResult } from "@codevisor/plugin-kit"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

import type { ShopifyCli } from "./shopify-cli.js"
import { ShopifyToolError } from "./shopify-store.js"

export interface ToolContext {
  readonly cli: ShopifyCli
  readonly store: string
}

type ToolRunner = (
  args: Record<string, unknown>,
  context: ToolContext
) => Promise<Record<string, unknown>>

export const runShopifyTool = async (
  name: string,
  args: Record<string, unknown>,
  context: ToolContext
): Promise<CallToolResult> => {
  const tool = toolRunners[name]
  if (tool === undefined) return errorResult(`Unknown tool: ${name}`)

  try {
    return compactResult({ store: context.store, ...(await tool(args, context)) })
  } catch (error) {
    return errorResult(failureMessage(error))
  }
}

const runQuery: ToolRunner = async (args, { cli, store }) => {
  const input = queryInput.parse(args)
  return cli.execute(store, { ...input, allowMutations: false })
}

const runAnalytics: ToolRunner = async (args, { cli, store }) => {
  const input = analyticsInput.parse(args)
  return cli.execute(store, {
    query: shopifyqlWrapper,
    variables: { query: input.query },
    allowMutations: false
  })
}

const runMutation: ToolRunner = async (args, { cli, store }) => {
  const input = mutationInput.parse(args)
  if (input.confirm !== true) throw new ShopifyToolError(confirmationRequired)

  return cli.execute(store, {
    query: input.mutation,
    variables: input.variables,
    allowMutations: true
  })
}

const toolRunners: Readonly<Record<string, ToolRunner>> = {
  run_query: runQuery,
  run_analytics: runAnalytics,
  run_mutation: runMutation
}

const compactResult = (value: Record<string, unknown>): CallToolResult => ({
  content: [{ type: "text", text: JSON.stringify(value) }],
  structuredContent: value
})

const failureMessage = (error: unknown): string => {
  if (error instanceof z.ZodError) return z.prettifyError(error)
  if (error instanceof ShopifyToolError) return error.message

  return `Shopify request failed: ${String(error)}`
}

const variables = z.record(z.string(), z.unknown()).optional()
const queryInput = z.object({ query: z.string().min(1), variables })
const analyticsInput = z.object({ query: z.string().min(1) })
const mutationInput = z.object({
  mutation: z.string().min(1),
  variables,
  confirm: z.boolean().optional()
})

const shopifyqlWrapper =
  "query ShopifyQL($query: String!) { shopifyqlQuery(query: $query) { tableData { columns { name dataType } rows } parseErrors } }"

const confirmationRequired =
  "Show the user exactly what this mutation changes in which store, get their explicit approval, then call run_mutation again with confirm: true."
