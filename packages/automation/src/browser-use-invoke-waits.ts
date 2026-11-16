import type { CallToolResult } from "@modelcontextprotocol/server"

import {
  evaluateReadOnly,
  jsonResult,
  stringArgument,
  type BrowserRuntime,
  type PageHandle
} from "./browser-cdp-engine.js"
import { delay } from "./browser-cdp.js"
import { responseBodyText, waitForNetworkEvent } from "./browser-network-wait.js"
import { urlMatcher } from "./browser-url-match.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"
import { waitBudget } from "./browser-wait-budget.js"
import { optionalString, recordOrUndefined } from "./unknown-values.js"

export const invokeWaitTools = async (
  { active, args, page, toolName }: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  switch (toolName) {
    case "playwright.waitForFunction":
      return jsonResult({ value: await waitForFunction(active, page, args) })
    case "playwright.waitForNetwork":
      return jsonResult(
        await waitForNetworkEvent(active, page, {
          kind: args.kind === "request" ? "request" : "response",
          matches: args.url === undefined ? anyUrl : urlMatcher(args.url, "url"),
          afterSequence:
            typeof args.afterSequence === "number" ? args.afterSequence : active.eventSequence,
          timeoutMs: waitBudget(args.timeoutMs)
        })
      )
    case "playwright.responseBody":
      return jsonResult({
        text: await responseBodyText(
          active,
          page,
          stringArgument(args, "requestId"),
          args.sessionId
        )
      })
    default:
      return undefined
  }
}

export const waitForPopup = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  timeoutMs: number
): Promise<CallToolResult> => {
  const afterSequence = runtime.eventSequence
  const deadline = Date.now() + timeoutMs
  while (true) {
    const popup = openedBy(runtime, page, afterSequence)
    if (popup !== undefined) return jsonResult({ event: "popup", ...popup })
    if (Date.now() >= deadline) throw new Error("Timed out waiting for the page to open a new tab")
    await delay(pollMs)
  }
}

const pollMs = 50
const defaultPollingMs = 100
const anyUrl = (): boolean => true

const waitForFunction = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  args: Readonly<Record<string, unknown>>
): Promise<unknown> => {
  const source = stringArgument(args, "function")
  const polling =
    typeof args.pollingMs === "number" ? Math.max(16, args.pollingMs) : defaultPollingMs
  const deadline = Date.now() + waitBudget(args.timeoutMs)
  while (true) {
    const value = await evaluateReadOnly(runtime, page, source, args.arg)
    if (value !== false && value !== null && value !== undefined && value !== 0 && value !== "")
      return value
    if (Date.now() >= deadline)
      throw new Error("Timed out waiting for the function to return a truthy value")
    await delay(polling)
  }
}

const openedBy = (
  runtime: BrowserRuntime,
  page: PageHandle,
  afterSequence: number
): { tabId: string; url: string } | undefined => {
  for (const event of runtime.eventLog) {
    if (event.sequence <= afterSequence || event.method !== "Target.targetCreated") continue
    const info = recordOrUndefined(event.params.targetInfo)
    if (info?.type !== "page" || info.openerId !== page.target.targetId) continue
    if (typeof info.targetId === "string")
      return { tabId: info.targetId, url: optionalString(info.url) ?? "" }
  }
  return undefined
}
