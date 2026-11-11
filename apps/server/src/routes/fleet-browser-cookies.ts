import {
  BrowserCookieShareRequest,
  maxSharedBrowserCookiesPerCall,
  type SharedBrowserCookieBatch
} from "@codevisor/api"
import { Option, Schema } from "effect"

import { HttpFailure, type CodevisorServerServices } from "../server-context.js"
import type { FleetCall } from "./fleet-calls.js"

const decodeRequest = Schema.decodeUnknownOption(BrowserCookieShareRequest)

export const receiveBrowserCookies = (
  services: CodevisorServerServices,
  call: FleetCall,
  args: unknown
): Promise<SharedBrowserCookieBatch> => {
  const share = services.browserCookieShare
  if (share === undefined) throw new HttpFailure(501, "Browser cookie sharing is unavailable here")
  if (!call.verified || share.refusesPeer(call.origin.machineId))
    throw new HttpFailure(403, "Only your own machines can share browser cookies")

  const request = decodeRequest(args)
  if (Option.isNone(request) || request.value.entries.length > maxSharedBrowserCookiesPerCall)
    throw new HttpFailure(400, "Expected { since, entries }")
  return share.answer(request.value)
}
