import { jsonResult } from "./browser-cdp-engine.js"

export const extensionConnectionReply = (connected: boolean) =>
  jsonResult({
    backend: "extension",
    connectionState: connected ? "connected" : "needs_setup",
    connected,
    next: connected
      ? "Call openTabs, then claimTab before inspecting or changing a page."
      : "Chrome is not connected. Codevisor handles browser selection and extension setup in the composer."
  })
