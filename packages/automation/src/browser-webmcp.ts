import type { JsonSchemaType } from "@modelcontextprotocol/server"
import { AjvJsonSchemaValidator } from "@modelcontextprotocol/server/validators/ajv"

import { evaluate, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import {
  isPlainRecord,
  optionalString,
  recordOrEmpty,
  type UnknownRecord
} from "./unknown-values.js"

export interface WebMcpToolSummary {
  readonly name: string
  readonly description: string
  readonly inputSchema?: UnknownRecord
  readonly annotations?: UnknownRecord
}

export interface WebMcpListing {
  readonly tools: ReadonlyArray<WebMcpToolSummary>
  readonly reason?: string
}

export type WebMcpCallResult =
  | { readonly status: "completed"; readonly result: unknown }
  | { readonly status: "awaitingUserSubmit"; readonly message: string }

export interface WebMcpCall {
  readonly name: string
  readonly input: UnknownRecord
  readonly timeoutMs: number
}

export const defaultWebMcpTimeoutMs = 30_000
export const maxWebMcpTimeoutMs = 120_000

export const listWebMcpTools = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<WebMcpListing> => {
  const registered = await registeredTools(runtime, page)
  if (registered === undefined) return { tools: [], reason: unsupportedReason }
  if (registered.length > 0) return { tools: registered.map(toolSummary) }

  return { tools: [], reason: await emptyPageReason(runtime, page) }
}

export const callWebMcpTool = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  call: WebMcpCall
): Promise<WebMcpCallResult> => {
  const tool = await requireTool(runtime, page, call.name)
  validateInput(tool, call.input)

  const responses = watchResponses(runtime, page)
  try {
    const invocationId = await invokeTool(runtime, page, tool, call.input)
    if (waitsForUserSubmit(tool)) return await formInvocation(responses, invocationId, tool)
    return await scriptInvocation(runtime, page, responses, invocationId, call)
  } finally {
    responses.stop()
  }
}

interface RegisteredTool extends WebMcpToolSummary {
  readonly frameId: string
  readonly backendNodeId?: number
}

interface ToolResponse {
  readonly status: string
  readonly output?: unknown
  readonly errorText?: string
  readonly exception?: UnknownRecord
}

interface ResponseWatcher {
  readonly next: (invocationId: string, timeoutMs: number) => Promise<ToolResponse | undefined>
  readonly stop: () => void
}

const unsupportedReason = "This browser doesn't support WebMCP."
const disabledReason =
  "WebMCP is turned off for this page. Chrome exposes it only with the WebMCP feature flag or a site origin trial."
const noToolsReason = "This page registers no WebMCP tools."
const formSubmitGraceMs = 1_000
const missingDomainPattern = /WebMCP\.enable' wasn't found/

const registeredTools = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<ReadonlyArray<RegisteredTool> | undefined> => {
  const tools = new Map<string, RegisteredTool>()
  const stop = runtime.connection.on(
    "WebMCP.toolsAdded",
    (params) => collectTools(tools, params),
    page.sessionId
  )
  try {
    await runtime.connection.send("WebMCP.enable", {}, page.sessionId)
    return [...tools.values()]
  } catch (cause) {
    if (missingDomainPattern.test(String(cause))) return undefined
    throw cause
  } finally {
    stop()
  }
}

const collectTools = (tools: Map<string, RegisteredTool>, params: UnknownRecord): void => {
  const added = Array.isArray(params.tools) ? params.tools : []
  for (const raw of added) {
    const tool = registeredTool(recordOrEmpty(raw))
    if (tool !== undefined && !tools.has(tool.name)) tools.set(tool.name, tool)
  }
}

const registeredTool = (raw: UnknownRecord): RegisteredTool | undefined => {
  const name = optionalString(raw.name)
  const frameId = optionalString(raw.frameId)
  if (name === undefined || frameId === undefined) return undefined

  return {
    name,
    description: optionalString(raw.description) ?? "",
    frameId,
    ...(isPlainRecord(raw.inputSchema) ? { inputSchema: raw.inputSchema } : {}),
    ...(isPlainRecord(raw.annotations) ? { annotations: raw.annotations } : {}),
    ...(typeof raw.backendNodeId === "number" ? { backendNodeId: raw.backendNodeId } : {})
  }
}

const toolSummary = (tool: RegisteredTool): WebMcpToolSummary => ({
  name: tool.name,
  description: tool.description,
  ...(tool.inputSchema === undefined ? {} : { inputSchema: tool.inputSchema }),
  ...(tool.annotations === undefined ? {} : { annotations: tool.annotations })
})

const emptyPageReason = async (runtime: BrowserRuntime, page: PageHandle): Promise<string> => {
  const exposed = await evaluate(runtime, page, "'modelContext' in document").catch(() => false)
  if (exposed === true) return noToolsReason
  return disabledReason
}

const requireTool = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  name: string
): Promise<RegisteredTool> => {
  const tools = await registeredTools(runtime, page)
  if (tools === undefined) throw new Error(unsupportedReason)
  if (tools.length === 0)
    throw new Error(`No WebMCP tool named ${name}: ${await emptyPageReason(runtime, page)}`)

  const tool = tools.find((candidate) => candidate.name === name)
  if (tool === undefined)
    throw new Error(`No WebMCP tool named ${name}. This page has: ${toolNames(tools)}`)
  return tool
}

const toolNames = (tools: ReadonlyArray<RegisteredTool>): string =>
  tools.map((tool) => tool.name).join(", ")

const validateInput = (tool: RegisteredTool, input: UnknownRecord): void => {
  const check = inputValidator(tool)
  const outcome = check(input)
  if (!outcome.valid) throw new Error(`Invalid input for ${tool.name}: ${outcome.errorMessage}`)
}

const inputValidator = (tool: RegisteredTool) => {
  try {
    return new AjvJsonSchemaValidator().getValidator(toolSchema(tool))
  } catch (cause) {
    throw new Error(`${tool.name} has an inputSchema that can't be checked: ${String(cause)}`, {
      cause
    })
  }
}

const toolSchema = (tool: RegisteredTool): JsonSchemaType => {
  const schema: JsonSchemaType = { type: "object", ...tool.inputSchema }
  return schema
}

const watchResponses = (runtime: BrowserRuntime, page: PageHandle): ResponseWatcher => {
  const responses = new Map<string, ToolResponse>()
  const waiters = new Map<string, () => void>()
  const stop = runtime.connection.on(
    "WebMCP.toolResponded",
    (params) => {
      const invocationId = optionalString(params.invocationId)
      if (invocationId === undefined) return
      responses.set(invocationId, toolResponse(params))
      waiters.get(invocationId)?.()
    },
    page.sessionId
  )
  return { next: (id, timeoutMs) => nextResponse(responses, waiters, id, timeoutMs), stop }
}

const nextResponse = (
  responses: ReadonlyMap<string, ToolResponse>,
  waiters: Map<string, () => void>,
  invocationId: string,
  timeoutMs: number
): Promise<ToolResponse | undefined> =>
  new Promise((resolve) => {
    const settle = () => {
      clearTimeout(timer)
      waiters.delete(invocationId)
      resolve(responses.get(invocationId))
    }
    const timer = setTimeout(settle, timeoutMs)
    timer.unref?.()
    waiters.set(invocationId, settle)
    if (responses.has(invocationId)) settle()
  })

const toolResponse = (params: UnknownRecord): ToolResponse => ({
  status: optionalString(params.status) ?? "Error",
  ...("output" in params ? { output: params.output } : {}),
  ...(typeof params.errorText === "string" ? { errorText: params.errorText } : {}),
  ...(isPlainRecord(params.exception) ? { exception: params.exception } : {})
})

const invokeTool = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  tool: RegisteredTool,
  input: UnknownRecord
): Promise<string> => {
  const started = await runtime.connection.send<{ invocationId?: unknown }>(
    "WebMCP.invokeTool",
    { frameId: tool.frameId, toolName: tool.name, input },
    page.sessionId
  )
  const invocationId = optionalString(started.invocationId)
  if (invocationId === undefined) throw new Error(`${tool.name} didn't start`)
  return invocationId
}

const waitsForUserSubmit = (tool: RegisteredTool): boolean =>
  tool.backendNodeId !== undefined && tool.annotations?.autosubmit !== true

const formInvocation = async (
  responses: ResponseWatcher,
  invocationId: string,
  tool: RegisteredTool
): Promise<WebMcpCallResult> => {
  const response = await responses.next(invocationId, formSubmitGraceMs)
  if (response !== undefined) return completedResult(tool, response)

  return {
    status: "awaitingUserSubmit",
    message: `The page filled the ${tool.name} form and is waiting for the user to submit it.`
  }
}

const scriptInvocation = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  responses: ResponseWatcher,
  invocationId: string,
  call: WebMcpCall
): Promise<WebMcpCallResult> => {
  const response = await responses.next(invocationId, call.timeoutMs)
  if (response !== undefined) return completedResult(call, response)

  await cancelInvocation(runtime, page, invocationId)
  throw new Error(`${call.name} didn't finish within ${call.timeoutMs} ms, so it was canceled`)
}

const cancelInvocation = (runtime: BrowserRuntime, page: PageHandle, invocationId: string) =>
  runtime.connection
    .send("WebMCP.cancelInvocation", { invocationId }, page.sessionId)
    .catch(() => undefined)

const completedResult = (
  tool: { readonly name: string },
  response: ToolResponse
): WebMcpCallResult => {
  if (response.status === "Completed") return { status: "completed", result: response.output }
  if (response.status === "Canceled") throw new Error(`${tool.name} was canceled by the page`)
  throw new Error(`${tool.name} failed: ${failureText(response)}`)
}

const failureText = (response: ToolResponse): string =>
  optionalString(response.exception?.description)?.split("\n")[0] ||
  response.errorText ||
  "the page reported an error"
