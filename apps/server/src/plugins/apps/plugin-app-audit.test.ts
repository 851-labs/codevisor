import { describe, expect, it, onTestFinished, vi } from "vitest"

import { makeAppAudit } from "./plugin-app-audit.js"
import { hasUiMeta, prefersBorder } from "./plugin-app-ui-meta.js"

const source = { serverId: "grafana", resourceUri: "ui://grafana/alerts.html" }

describe("plugin app audit", () => {
  it("records each app CSP once and every log line, capped, in the server log", () => {
    const lines: Array<string> = []
    const audit = makeAppAudit((line) => lines.push(line))

    audit.policy(source, "default-src 'none'")
    audit.policy(source, "default-src 'none'")
    audit.message(source, { data: "x".repeat(4_010) })
    audit.message(source, { level: "debug", logger: "chart", data: "drawn" })

    expect(lines.map((line) => JSON.parse(line))).toEqual([
      { event: "plugin_app_csp", ...source, policy: "default-src 'none'" },
      { event: "plugin_app_log", ...source, level: "info", data: `${"x".repeat(4_000)}…` },
      { event: "plugin_app_log", ...source, level: "debug", logger: "chart", data: "drawn" }
    ])
  })

  it("writes to stderr by default", () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
    onTestFinished(() => logged.mockRestore())

    makeAppAudit().message(source, {})

    expect(logged).toHaveBeenCalledWith(
      JSON.stringify({ event: "plugin_app_log", ...source, level: "info", data: "" })
    )
  })
})

describe("plugin app UI metadata", () => {
  it("reads the border preference and ignores malformed metadata", () => {
    expect(prefersBorder({ ui: { prefersBorder: false } })).toBe(false)
    expect(prefersBorder({ ui: {} })).toBeUndefined()
    expect(prefersBorder(undefined)).toBeUndefined()
    expect(hasUiMeta({ ui: { csp: {} } })).toBe(true)
    expect(hasUiMeta({ other: true })).toBe(false)
    expect(hasUiMeta({ ui: { prefersBorder: "yes" } })).toBe(false)
  })
})
