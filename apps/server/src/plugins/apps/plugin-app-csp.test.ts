import { describe, expect, it } from "vitest"

import { appPolicy, appSandbox, frameAllow, shellPolicy } from "./plugin-app-csp.js"

describe("plugin app sandbox", () => {
  it("keeps only web origins an app declares and grants only clipboard writes", () => {
    const sandbox = appSandbox({
      ui: {
        csp: {
          connectDomains: [
            "https://api.example",
            "wss://live.example:8443",
            "http://plain.example"
          ],
          resourceDomains: ["https://*.cdn.example", "'unsafe-eval'"],
          frameDomains: ["https://player.example"],
          baseUriDomains: ["javascript:alert(1)"]
        },
        permissions: { clipboardWrite: {}, camera: {} }
      }
    })

    expect(sandbox).toEqual({
      csp: {
        connectDomains: ["https://api.example", "wss://live.example:8443"],
        resourceDomains: ["https://*.cdn.example"],
        frameDomains: ["https://player.example"],
        baseUriDomains: []
      },
      permissions: { clipboardWrite: {} }
    })
    expect(frameAllow(sandbox.permissions)).toBe("clipboard-write")
    expect(appPolicy(sandbox.csp)).toBe(
      [
        "default-src 'none'",
        "script-src 'unsafe-inline' https://*.cdn.example",
        "style-src 'unsafe-inline' https://*.cdn.example",
        "img-src data: blob: https://*.cdn.example",
        "font-src data: https://*.cdn.example",
        "media-src data: blob: https://*.cdn.example",
        "connect-src https://api.example wss://live.example:8443",
        "frame-src https://player.example",
        "base-uri 'none'",
        "object-src 'none'",
        "form-action 'none'"
      ].join("; ")
    )
    expect(shellPolicy(sandbox.csp)).toContain(
      "connect-src 'self' https://api.example wss://live.example:8443"
    )
  })

  it("falls back to the restrictive defaults", () => {
    for (const meta of [undefined, { ui: { csp: { connectDomains: "everything" } } }]) {
      const sandbox = appSandbox(meta)
      expect(sandbox.permissions).toEqual({})
      expect(frameAllow(sandbox.permissions)).toBe("")
      expect(appPolicy(sandbox.csp)).toContain("script-src 'unsafe-inline'; ")
      expect(appPolicy(sandbox.csp)).toContain("connect-src 'none'; frame-src 'none'")
    }
  })
})
