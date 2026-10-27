import type { CodevisorExecutionApp } from "@codevisor/api"
import type { CallToolResult, Tool } from "@modelcontextprotocol/sdk/types.js"
import { z } from "zod"

export const APP_RESULT_MAX_BYTES = 1024 * 1024

export const TRUNCATED_META_KEY = "dev.codevisor/truncated"

export type PluginAppCaller = "model" | "app"

export interface PluginAppView extends CodevisorExecutionApp {
  readonly sessionId: string
  readonly accountId?: string
  readonly toolInput: Record<string, unknown>
  readonly toolResult: CallToolResult
  readonly createdAt: string
}

export const appResourceUri = (tool: Tool): string | undefined => {
  const meta = ToolUiMetaSchema.safeParse(tool._meta).data
  const uri = meta?.ui?.resourceUri ?? meta?.["ui/resourceUri"] ?? meta?.["openai/outputTemplate"]
  if (uri === undefined || !uri.startsWith("ui://")) return undefined
  return uri
}

export const toolVisibleTo = (tool: Tool, caller: PluginAppCaller): boolean => {
  const visibility = ToolUiMetaSchema.safeParse(tool._meta).data?.ui?.visibility
  if (visibility === undefined) return true
  return visibility.includes(caller)
}

export const appViewRef = (view: PluginAppView): CodevisorExecutionApp => ({
  viewId: view.viewId,
  machineId: view.machineId,
  serverId: view.serverId,
  serverName: view.serverName,
  toolName: view.toolName,
  resourceUri: view.resourceUri
})

export const cappedToolResult = (
  result: CallToolResult,
  maxBytes: number = APP_RESULT_MAX_BYTES
): CallToolResult => {
  if (jsonBytes(result) <= maxBytes) return result

  let left = maxBytes
  const fits = (value: unknown): boolean => {
    const size = jsonBytes(value)
    if (size > left) return false
    left -= size
    return true
  }
  const keepMeta = result._meta !== undefined && fits(result._meta)
  const keepStructured = result.structuredContent !== undefined && fits(result.structuredContent)
  return {
    content: result.content.filter(fits),
    ...(keepStructured ? { structuredContent: result.structuredContent } : {}),
    ...(result.isError === undefined ? {} : { isError: result.isError }),
    _meta: { ...(keepMeta ? result._meta : {}), [TRUNCATED_META_KEY]: true }
  }
}

export interface AppViewCapture {
  readonly viewId: string
  readonly machineId: string
  readonly sessionId: string | undefined
  readonly server: { readonly id: string; readonly name: string }
  readonly tool: Tool | undefined
  readonly accountId: string | undefined
  readonly toolInput: Record<string, unknown>
  readonly toolResult: CallToolResult
  readonly createdAt: string
}

export const capturedAppView = (capture: AppViewCapture): PluginAppView | undefined => {
  const resourceUri = capture.tool === undefined ? undefined : appResourceUri(capture.tool)
  if (resourceUri === undefined || capture.sessionId === undefined) return undefined
  return {
    viewId: capture.viewId,
    machineId: capture.machineId,
    sessionId: capture.sessionId,
    serverId: capture.server.id,
    serverName: capture.server.name,
    toolName: capture.tool!.name,
    resourceUri,
    ...(capture.accountId === undefined ? {} : { accountId: capture.accountId }),
    toolInput: capture.toolInput,
    toolResult: cappedToolResult(capture.toolResult),
    createdAt: capture.createdAt
  }
}

const ToolUiMetaSchema = z.looseObject({
  ui: z
    .looseObject({
      resourceUri: z.string().optional(),
      visibility: z.array(z.string()).optional()
    })
    .optional(),
  "ui/resourceUri": z.string().optional(),
  "openai/outputTemplate": z.string().optional()
})

const jsonBytes = (value: unknown): number => Buffer.byteLength(JSON.stringify(value))
