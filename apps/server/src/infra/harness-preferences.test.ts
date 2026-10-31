import { describe, expect, it } from "vitest"

import { makeServices, run } from "../test-support.js"
import {
  decorateHarnessSettings,
  effectiveHarnessPreference,
  HARNESSES_SYNC_NAMESPACE,
  harnessPreference,
  readHarnessSettings,
  setHarnessPreference
} from "./harness-preferences.js"

const timestamp = { wallMs: 1, counter: 0, deviceId: "test" }
describe("harness preferences", () => {
  it("rejects invalid rows and never infers destructive intent from legacy absence", () => {
    for (const value of [null, [], {}, { enabled: "yes" }, { installed: 1 }, { installed: false }])
      expect(harnessPreference(value)).toBeUndefined()
    expect(harnessPreference({ enabled: true, installed: true })).toEqual({
      enabled: true,
      installed: true
    })
    expect(harnessPreference({ enabled: false, installed: false })).toBeUndefined()
    expect(harnessPreference({ enabled: false, installed: false, uninstall: true })).toEqual({
      enabled: false,
      installed: false
    })
    expect(effectiveHarnessPreference(undefined)).toEqual({})
    expect(effectiveHarnessPreference({ global: { enabled: true, installed: false } })).toEqual({
      enabled: false,
      installed: false
    })
  })

  it("writes catalog rows in the Settings page's shape and reports what changed", async () => {
    const { services } = await makeServices("preferences-write")
    const identity = { id: "codex", name: "Codex", symbolName: "chevron" }
    const first = await setHarnessPreference(services.db, "machine-a", identity, {
      enabled: true,
      installed: true
    })
    expect(first.map((entry) => entry.key)).toEqual(["codex"])
    expect(first[0]?.value).toEqual({
      name: "Codex",
      symbolName: "chevron",
      enabled: true,
      installed: true,
      uninstall: false
    })
    expect(first[0]?.timestamp.deviceId).toBe("machine-a")

    const same = await setHarnessPreference(services.db, "machine-a", identity, {
      enabled: true,
      installed: true
    })
    expect(same.map((entry) => entry.key)).toEqual(["codex"])

    const uninstall = await setHarnessPreference(services.db, "machine-a", identity, {
      enabled: false,
      installed: false
    })
    expect(uninstall[0]?.value).toMatchObject({ enabled: false, installed: false, uninstall: true })
    expect((await readHarnessSettings(services.db)).get("codex")).toEqual({
      global: { enabled: false, installed: false }
    })
  })

  it("decorates discovery with the catalog's desired state", async () => {
    const { services } = await makeServices("preferences-decorate")
    await run(
      services.db.mergeSyncEntries(HARNESSES_SYNC_NAMESPACE, [
        { key: "codex", value: { enabled: false, installed: true }, timestamp }
      ])
    )
    const harnesses = await run(services.agents.discoverHarnesses)
    const first = harnesses[0]!
    const decorated = await decorateHarnessSettings(services.db, [
      { ...first, id: "codex", enabled: true, desiredEnabled: true },
      { ...first, id: "other", enabled: false, desiredEnabled: true }
    ])
    expect(decorated[0]?.desiredEnabled).toBe(false)
    expect(decorated[0]?.enabled).toBe(false)
    expect(decorated[1]?.desiredEnabled).toBe(true)
  })
})
