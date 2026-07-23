import { describe, expect, it, vi } from "vitest"
import { initializeOptionalServerFeature, initializeOptionalServerFeatureAsync } from "./serve.js"

describe("optional server feature initialization", () => {
  it("keeps synchronous feature failures inside their feature boundary", () => {
    const report = vi.fn()
    const result = initializeOptionalServerFeature(
      "Browser Use",
      () => {
        throw new Error("extension missing")
      },
      report
    )

    expect(result).toBeUndefined()
    expect(report).toHaveBeenCalledWith("Browser Use unavailable: extension missing")
  })

  it("keeps asynchronous feature failures inside their feature boundary", async () => {
    const report = vi.fn()
    const result = await initializeOptionalServerFeatureAsync(
      "Custom harnesses",
      async () => {
        throw new Error("settings unreadable")
      },
      report
    )

    expect(result).toBeUndefined()
    expect(report).toHaveBeenCalledWith("Custom harnesses unavailable: settings unreadable")
  })

  it("returns successfully initialized features unchanged", async () => {
    const feature = { ready: true }
    expect(initializeOptionalServerFeature("MCP", () => feature)).toBe(feature)
    await expect(initializeOptionalServerFeatureAsync("Skills", async () => feature)).resolves.toBe(
      feature
    )
  })
})
