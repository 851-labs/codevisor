import type { SyncEntryRecord } from "@codevisor/sync"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import {
  syncedChoiceEnabled,
  syncedTelemetrySettings,
  telemetryContext
} from "./telemetry-settings.js"

const timestamp = { wallMs: 1, counter: 0, deviceId: "mac" }

const database = (
  settings: ReadonlyArray<Omit<SyncEntryRecord, "timestamp">>,
  flags: ReadonlyArray<Omit<SyncEntryRecord, "timestamp">> = []
) => ({
  getSyncEntries: (namespace: string) =>
    Effect.succeed(
      (namespace === "settings" ? settings : flags).map((entry) => ({ ...entry, timestamp }))
    )
})

describe("telemetry settings", () => {
  it("treats a choice as off until a client turns it on", async () => {
    expect(await syncedChoiceEnabled(database([]), "shareAnalytics")).toBe(false)
    expect(
      await syncedChoiceEnabled(
        database([{ key: "shareAnalytics", value: false }]),
        "shareAnalytics"
      )
    ).toBe(false)
    expect(
      await syncedChoiceEnabled(
        database([{ key: "shareAnalytics", value: true, deleted: true }]),
        "shareAnalytics"
      )
    ).toBe(false)
    expect(
      await syncedChoiceEnabled(
        database([{ key: "shareCrashReports", value: true }]),
        "shareAnalytics"
      )
    ).toBe(false)
    expect(
      await syncedChoiceEnabled(
        database([{ key: "shareAnalytics", value: true }]),
        "shareAnalytics"
      )
    ).toBe(true)
  })

  it("describes the synced update channel and every enabled flag", async () => {
    const db = database(
      [{ key: "updateChannel", value: "alpha" }],
      [
        { key: "slackPlugin", value: true },
        { key: "developerMode", value: true },
        { key: "gmailPlugin", value: false }
      ]
    )
    expect(await telemetryContext(syncedTelemetrySettings(db, "shareAnalytics"))).toEqual({
      updateChannel: "alpha",
      flags: ["developerMode", "slackPlugin"]
    })
    expect(await telemetryContext(syncedTelemetrySettings(database([]), "shareAnalytics"))).toEqual(
      {
        updateChannel: "stable",
        flags: []
      }
    )
  })
})
