import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"

import { textToolResult } from "./automation-provider.js"
import { CodeExecutionToolError } from "./code-executor.js"
import type { CodevisorApiToolSpec } from "./codevisor-api-tools.js"
import { withClampNote } from "./codevisor-wait-budget.js"
import { isRecord, recordOrEmpty, recordOrUndefined, type UnknownRecord } from "./unknown-values.js"

export const responseError = async (
  spec: CodevisorApiToolSpec,
  response: Response
): Promise<Error> => {
  const text = await response.text()
  let detail = text.trim()
  let typed: UnknownRecord = {}
  try {
    const parsed = recordOrEmpty(JSON.parse(text))
    typed = isRecord(parsed.error) ? parsed.error : { ...parsed, message: parsed.error }
    if (typeof typed.message === "string") detail = typed.message
  } catch {}
  const code = typeof typed.code === "string" ? typed.code : undefined
  const details = recordOrUndefined(typed.details)
  const message = `${spec.name} failed (${response.status}${response.statusText.length === 0 ? "" : ` ${response.statusText}`}): ${detail || "Codevisor request failed"}`
  return code === undefined
    ? new Error(message)
    : new CodeExecutionToolError(detail, { code, ...(details === undefined ? {} : { details }) })
}

export const resourceResult = (url: URL, response: Response, bytes: Buffer): CallToolResult => ({
  content: [
    {
      type: "resource",
      resource: {
        uri: url.toString(),
        mimeType: response.headers.get("content-type") ?? "application/octet-stream",
        blob: bytes.toString("base64")
      }
    }
  ]
})

export const textResult = (
  response: Response,
  text: string,
  clampedToMs: number | undefined
): CallToolResult => {
  if (text.length === 0) return emptyResult(response.status)
  if (isJsonResponse(response)) return textToolResult(withClampNote(compactJson(text), clampedToMs))
  return textToolResult(text)
}

const emptyResult = (status: number): CallToolResult =>
  textToolResult(JSON.stringify({ ok: true, status }))

const isJsonResponse = (response: Response): boolean =>
  (response.headers.get("content-type") ?? "").includes("application/json")

const compactJson = (text: string): string => JSON.stringify(JSON.parse(text) as unknown)
