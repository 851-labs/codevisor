import type { CallToolResult } from "@modelcontextprotocol/server"

import { jsonResult } from "./browser-cdp-engine.js"
import { clearTabGeolocation, setTabGeolocation } from "./browser-geolocation.js"
import type { BrowserToolInvocation, BrowserToolSessionState } from "./browser-use-invoke-types.js"

export const invokeGeolocationTools = async (
  { active, args, page, toolName }: BrowserToolInvocation,
  _state: BrowserToolSessionState
): Promise<CallToolResult | undefined> => {
  if (toolName === "geolocation.set")
    return jsonResult({ ...(await setTabGeolocation(active, page, args)) })
  if (toolName !== "geolocation.clear") return undefined

  await clearTabGeolocation(active, page)
  return jsonResult({ cleared: true })
}
