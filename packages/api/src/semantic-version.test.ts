import { describe, expect, it } from "vitest"
import {
  compareSemanticVersions,
  isSemanticVersion,
  parseSemanticVersion
} from "./semantic-version.js"
import { isSupportedPluginProtocolVersion } from "./plugins.js"

describe("semantic versions", () => {
  it("accepts strict SemVer 2.0.0 versions", () => {
    expect(parseSemanticVersion("1.2.3")).toEqual({
      major: 1,
      minor: 2,
      patch: 3,
      prerelease: []
    })
    expect(isSemanticVersion("0.1.0-rc.2+darwin.1")).toBe(true)
  })

  it("rejects shorthand, prefixes, empty identifiers, and numeric leading zeros", () => {
    for (const version of [
      "1.2",
      "v1.2.3",
      "01.2.3",
      "1.2.3-01",
      "1.2.3-",
      "1.2.3+",
      "1.2.3+a+b",
      "1.2.3+bad_identifier",
      "1.2.3-alpha..1",
      "1.2.3-alpha_1",
      " 1.2.3"
    ]) {
      expect(isSemanticVersion(version), version).toBe(false)
    }
    expect(isSemanticVersion("1.2.3-0")).toBe(true)
  })

  it("orders cores and prereleases and ignores build metadata", () => {
    expect(compareSemanticVersions("2.0.0", "1.99.99")).toBe(1)
    expect(compareSemanticVersions("1.0.0", "1.0.0-rc.9")).toBe(1)
    expect(compareSemanticVersions("1.0.0-rc.10", "1.0.0-rc.2")).toBe(1)
    expect(compareSemanticVersions("1.0.0-alpha", "1.0.0-1")).toBe(1)
    expect(compareSemanticVersions("1.0.0-1", "1.0.0-alpha")).toBe(-1)
    expect(compareSemanticVersions("1.0.0-alpha", "1.0.0-beta")).toBe(-1)
    expect(compareSemanticVersions("1.0.0-beta", "1.0.0-alpha")).toBe(1)
    expect(compareSemanticVersions("1.0.0-alpha", "1.0.0-alpha")).toBe(0)
    expect(compareSemanticVersions("1.0.0-alpha", "1.0.0-alpha.1")).toBe(-1)
    expect(compareSemanticVersions("1.0.0-alpha.1", "1.0.0-alpha")).toBe(1)
    expect(compareSemanticVersions("1.0.0-2", "1.0.0-10")).toBe(-1)
    expect(compareSemanticVersions("1.0.0-2", "1.0.0-2")).toBe(0)
    expect(compareSemanticVersions("1.0.0-rc.2", "1.0.0-rc.10")).toBe(-1)
    expect(compareSemanticVersions("1.0.0-rc.2", "1.0.0-rc.2.0")).toBe(-1)
    expect(compareSemanticVersions("1.0.0-rc.2.0", "1.0.0-rc.2")).toBe(1)
    expect(compareSemanticVersions("1.0.0-rc.2", "1.0.0")).toBe(-1)
    expect(compareSemanticVersions("0.9.9", "1.0.0")).toBe(-1)
    expect(compareSemanticVersions("1.0.0+one", "1.0.0+two")).toBe(0)
    expect(compareSemanticVersions("999999999999999999999.0.0", "999999999999999999998.0.0")).toBe(
      1
    )
  })

  it("refuses to compare invalid input", () => {
    expect(() => compareSemanticVersions("latest", "1.0.0")).toThrow(/invalid semantic versions/)
  })

  it("recognizes every supported plugin protocol version", () => {
    expect(isSupportedPluginProtocolVersion(1)).toBe(true)
    expect(isSupportedPluginProtocolVersion(2)).toBe(true)
    expect(isSupportedPluginProtocolVersion(3)).toBe(false)
  })
})
