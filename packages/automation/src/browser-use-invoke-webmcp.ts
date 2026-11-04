import type { CallToolResult } from "@modelcontextprotocol/server"

import { jsonResult, stringArgument } from "./browser-cdp-engine.js"
import type { BrowserToolInvocation } from "./browser-use-invoke-types.js"
import {
  callWebMcpTool,
  defaultWebMcpTimeoutMs,
  listWebMcpTools,
  maxWebMcpTimeoutMs
} from "./browser-webmcp.js"
import { isPlainRecord, type UnknownRecord } from "./unknown-values.js"

export const invokeWebMcpTools = async (
  invocation: BrowserToolInvocation
): Promise<CallToolResult | undefined> => {
  const { active, args, page, toolName } = invocation
  switch (toolName) {
    case "webmcp.list":
      return jsonResult(await listWebMcpTools(active, page))
    case "webmcp.call":
      return jsonResult(
        await callWebMcpTool(active, page, {
          name: stringArgument(args, "name"),
          input: toolInput(args.input),
          timeoutMs: callTimeout(args.timeoutMs)
        })
      )
    default:
      return undefined
  }
}

const minWebMcpTimeoutMs = 1_000

const toolInput = (input: unknown): UnknownRecord => {
  if (input === undefined) return {}
  if (!isPlainRecord(input)) throw new Error("input must be an object")
  return input
}

const callTimeout = (timeoutMs: unknown): number => {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs)) return defaultWebMcpTimeoutMs
  return Math.max(minWebMcpTimeoutMs, Math.min(maxWebMcpTimeoutMs, timeoutMs))
}
