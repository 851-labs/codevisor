import { describe, expect, it } from "vitest"
import { makeServices, run } from "../test-support.js"
import {
  decorateHarnessSettings,
  effectiveHarnessPreference,
  harnessPreference,
  readHarnessSettings,
  setHarnessOverride
} from "./harness-preferences.js"

const timestamp = { wallMs: 1, counter: 0, deviceId: "test" }
describe("harness settings inheritance", () => {
  it("rejects invalid preferences and does not infer destructive intent", () => {
    for (const value of [null, [], {}, { enabled: "yes" }, { installed: 1 }])
      expect(harnessPreference(value)).toBeUndefined()
    expect(harnessPreference({ installed: false })).toEqual({ installed: false })
    expect(harnessPreference({ enabled: true })).toEqual({ enabled: true })
    expect(harnessPreference({ enabled: false, installed: false }, true)).toBeUndefined()
    expect(effectiveHarnessPreference(undefined)).toEqual({})
  })

  it("retains custom edits until reset, independently of the shared catalog", async () => {
    const { services } = await makeServices("preferences")
    await run(
      services.db.mergeSyncEntries("harnesses", [
        { key: "codex", value: { enabled: true, installed: true }, timestamp }
      ])
    )
    await run(
      services.db.mergeSyncEntries("local.harness-overrides", [
        { key: "junk", value: {}, timestamp }
      ])
    )
    await run(
      services.db.mergeSyncEntries("local.harness-custom-overrides", [
        { key: "codex", value: true, timestamp },
        { key: "custom", value: true, timestamp }
      ])
    )
    expect((await readHarnessSettings(services.db)).get("codex")).toEqual({
      global: { enabled: true, installed: true },
      override: {}
    })
    expect((await readHarnessSettings(services.db)).has("junk")).toBe(false)
    await setHarnessOverride(services.db, "codex", { enabled: false })
    expect((await readHarnessSettings(services.db)).get("codex")?.override).toEqual({
      enabled: false
    })
    await setHarnessOverride(services.db, "codex", undefined)
    expect((await readHarnessSettings(services.db)).get("codex")).toEqual({
      global: { enabled: true, installed: true }
    })
    const harnesses = await run(services.agents.discoverHarnesses)
    const first = harnesses[0]!
    const decorated = await decorateHarnessSettings(services.db, [
      { ...first, id: "other", enabled: false, desiredEnabled: true }
    ])
    expect(decorated[0]?.desiredEnabled).toBe(true)
  })
})
