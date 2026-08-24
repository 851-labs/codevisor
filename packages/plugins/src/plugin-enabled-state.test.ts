import { describe, expect, it } from "vitest"
import { isPluginEnabled, setPluginEnabledState } from "./plugin-enabled-state.js"
import { makeDir } from "./test-support.js"

describe("plugin enabled state", () => {
  it("defaults legacy installs to enabled and persists both transitions", async () => {
    const root = makeDir("codevisor-plugin-enabled-")
    expect(isPluginEnabled(root, "owner.example")).toBe(true)
    await setPluginEnabledState(root, "owner.example", false)
    expect(isPluginEnabled(root, "owner.example")).toBe(false)
    await setPluginEnabledState(root, "owner.example", true)
    expect(isPluginEnabled(root, "owner.example")).toBe(true)
  })
})
