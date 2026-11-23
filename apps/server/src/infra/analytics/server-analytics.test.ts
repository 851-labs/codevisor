import { describe, expect, it } from "vitest"

import type { TelemetrySettings } from "../telemetry/telemetry-settings.js"
import type { PostHogEvent } from "./posthog-transport.js"
import { makeServerAnalytics } from "./server-analytics.js"

const settings = (enabled: boolean): TelemetrySettings => ({
  enabled: async () => enabled,
  enabledFlags: async () => new Set(["slackPlugin", "developerMode"]),
  updateChannel: async () => "alpha"
})

const analytics = (options: { enabled?: boolean; send?: () => Promise<void> } = {}) => {
  const sent: PostHogEvent[] = []
  const reporter = makeServerAnalytics({
    settings: settings(options.enabled ?? true),
    send:
      options.send ??
      (async (event) => {
        sent.push(event)
      }),
    distinctId: "machine-hash",
    properties: { platform: "server", release_channel: "release" },
    now: () => new Date("2026-11-22T00:00:00.000Z")
  })
  return { reporter, sent }
}

const layoutEvent = {
  name: "agent layout changed",
  properties: { action: "split", in_bot: true }
} as const

describe("makeServerAnalytics", () => {
  it("sends nothing until usage analytics is turned on", async () => {
    const off = analytics({ enabled: false })
    await off.reporter.capture(layoutEvent)
    expect(off.sent).toEqual([])
  })

  it("sends an anonymous event with the machine's context and every enabled flag", async () => {
    const on = analytics()
    await on.reporter.capture(layoutEvent)
    expect(on.sent).toEqual([
      {
        event: "agent layout changed",
        distinct_id: "machine-hash",
        timestamp: "2026-11-22T00:00:00.000Z",
        properties: {
          platform: "server",
          release_channel: "release",
          update_channel: "alpha",
          feature_flags: ["developerMode", "slackPlugin"],
          flag_developerMode: true,
          flag_slackPlugin: true,
          action: "split",
          in_bot: true,
          $process_person_profile: false,
          $geoip_disable: true
        }
      }
    ])
  })

  it("never throws when sending fails", async () => {
    const failing = analytics({
      send: async () => {
        throw new Error("offline")
      }
    })
    await expect(failing.reporter.capture(layoutEvent)).resolves.toBe(undefined)
  })
})
