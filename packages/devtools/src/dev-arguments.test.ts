import { describe, expect, it } from "vitest"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.ts"

describe("parseDevelopmentRunnerArguments", () => {
  it("maps each runner to its target", () => {
    expect(parseDevelopmentRunnerArguments([])).toEqual({ target: "macos", reuseMacOSBuild: false })
    expect(parseDevelopmentRunnerArguments(["--ios"]).target).toBe("ios")
    expect(parseDevelopmentRunnerArguments(["--linux"]).target).toBe("linux")
  })

  it("reuses the macOS build on any runner", () => {
    expect(parseDevelopmentRunnerArguments(["--reuse-macos-build"]).reuseMacOSBuild).toBe(true)
    expect(parseDevelopmentRunnerArguments(["--ios", "--reuse-macos-build"])).toEqual({
      target: "ios",
      reuseMacOSBuild: true
    })
  })

  it("rejects the retired flags, unknown flags, and two runners at once", () => {
    for (const retired of [
      "--no-ios",
      "--no-containers",
      "--containers",
      "--container-engine=apple"
    ])
      expect(() => parseDevelopmentRunnerArguments([retired])).toThrow(
        /Unknown development runner argument.*dev:linux/
      )
    expect(() => parseDevelopmentRunnerArguments(["--ios", "--linux"])).toThrow(/Pick one/)
  })
})
