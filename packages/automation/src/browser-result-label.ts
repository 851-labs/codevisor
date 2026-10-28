import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import { jsonResult } from "./browser-cdp-engine.js"
import type { BrowserLabel } from "./browser-use-status.js"
import { isPlainRecord } from "./unknown-values.js"

const labeledTools = new Set(["tabs", "tab_info"])

export const labelBrowserResult = (
  toolName: string,
  result: CallToolResult,
  label: BrowserLabel
): CallToolResult => {
  if (result.isError === true || !labeledTools.has(toolName)) return result

  const value = singleJsonObject(result)
  if (value === undefined) return result

  return jsonResult({ ...value, browser: label })
}

const singleJsonObject = (result: CallToolResult): Record<string, unknown> | undefined => {
  const [only, ...rest] = result.content
  if (only?.type !== "text" || rest.length > 0) return undefined

  const value = parsedJson(only.text)
  return isPlainRecord(value) ? value : undefined
}

const parsedJson = (text: string): unknown => {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}
