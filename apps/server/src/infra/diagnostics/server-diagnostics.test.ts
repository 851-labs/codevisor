import { describe, expect, it } from "vitest"

import type { TelemetrySettings } from "../telemetry/telemetry-settings.js"
import type { SentryEvent } from "./sentry-event.js"
import { makeServerDiagnostics } from "./server-diagnostics.js"

const settings = (overrides: Partial<TelemetrySettings> = {}): TelemetrySettings => ({
  enabled: async () => true,
  enabledFlags: async () => new Set(["slackPlugin", "developerMode"]),
  updateChannel: async () => "alpha",
  ...overrides
})

const diagnostics = (
  options: { settings?: TelemetrySettings; send?: () => Promise<void> } = {}
) => {
  const sent: SentryEvent[] = []
  let clock = 1_000_000
  const reporter = makeServerDiagnostics({
    settings: options.settings ?? settings(),
    environment: {
      release: "codevisor-server@1.2.3",
      environment: "production",
      tags: { os: "darwin" }
    },
    send:
      options.send ??
      (async (event) => {
        sent.push(event)
      }),
    now: () => clock
  })
  return {
    reporter,
    sent,
    advance: (ms: number) => {
      clock += ms
    }
  }
}

const tenMinutes = 10 * 60_000

describe("makeServerDiagnostics", () => {
  it("sends nothing until crash reports are turned on", async () => {
    const off = diagnostics({ settings: settings({ enabled: async () => false }) })
    await off.reporter.capture(new Error("boom"), { component: "http" })
    expect(off.sent).toEqual([])
  })

  it("sends a scrubbed exception tagged with every enabled flag and the update channel", async () => {
    const on = diagnostics()
    const cause = new Error("open /Users/someone/acme/app.ts failed", {
      cause: new TypeError("token=hunter2 rejected")
    })

    await on.reporter.capture(cause, { component: "http", tags: { route: "GET /v1/sessions" } })

    const [event] = on.sent
    expect(event?.release).toBe("codevisor-server@1.2.3")
    expect(event?.tags).toEqual({
      os: "darwin",
      route: "GET /v1/sessions",
      component: "http",
      update_channel: "alpha",
      feature_flags: "developerMode,slackPlugin",
      flag_developerMode: "true",
      flag_slackPlugin: "true"
    })
    expect(event?.exception.values.map(({ type, value }) => ({ type, value }))).toEqual([
      { type: "TypeError", value: "token=<redacted> rejected" },
      { type: "Error", value: "open <path> failed" }
    ])
    expect(event?.exception.values[1]?.stacktrace?.frames.at(-1)).toMatchObject({
      filename: expect.stringMatching(
        /^apps\/server\/src\/infra\/diagnostics\/server-diagnostics\.test\.ts$/
      ),
      in_app: true
    })
    expect(event?.fingerprint).toEqual(["{{ default }}", "http"])
  })

  it("groups by message when asked and reports non-errors as text", async () => {
    const on = diagnostics()
    await on.reporter.capture("socket closed", { component: "turn", groupBy: "socket closed" })
    expect(on.sent[0]?.fingerprint).toEqual(["turn", "socket closed"])
    expect(on.sent[0]?.exception.values).toEqual([{ type: "NonError", value: "socket closed" }])
  })

  it("reports each distinct failure once per window and caps the window's total", async () => {
    const on = diagnostics()
    await on.reporter.capture(new Error("same"), { component: "http" })
    await on.reporter.capture(new Error("same"), { component: "http" })
    for (let index = 0; index < 30; index += 1) {
      await on.reporter.capture(new Error(`distinct ${index}`), { component: "http" })
    }
    expect(on.sent).toHaveLength(20)

    on.advance(tenMinutes)
    await on.reporter.capture(new Error("same"), { component: "http" })
    expect(on.sent).toHaveLength(21)
  })

  it("never throws when sending fails", async () => {
    const failing = diagnostics({
      send: async () => {
        throw new Error("offline")
      }
    })
    await expect(failing.reporter.capture(new Error("boom"), { component: "http" })).resolves.toBe(
      undefined
    )
  })
})
