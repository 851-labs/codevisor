import { describe, expect, it } from "vitest"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.ts"
import { requestsMacOSBuildReuse, verifyReusableMacOSApp } from "./dev-macos-reuse.ts"

const plutil = [
  "/usr/bin/plutil",
  "-convert",
  "json",
  "-o",
  "-",
  "/owned/Debug/Example.app/Contents/Info.plist"
]
const codesign = ["/usr/bin/codesign", "--verify", "--deep", "--strict", "/owned/Debug/Example.app"]
const goodMetadata = JSON.stringify({
  CFBundleIdentifier: "dev.example",
  CFBundleExecutable: "Example"
})

const fixture = (
  overrides: { capture?: () => Promise<string>; run?: () => Promise<unknown> } = {}
) => {
  const calls: Array<Array<string>> = []
  return {
    calls,
    app: {
      appBundle: "/owned/Debug/Example.app",
      bundleIdentifier: "dev.example",
      executableName: "Example",
      capture: async (command: string, args: Array<string>) => {
        calls.push([command, ...args])
        return (overrides.capture ?? (async () => goodMetadata))()
      },
      run: async (command: string, args: Array<string>) => {
        calls.push([command, ...args])
        return (overrides.run ?? (async () => undefined))()
      }
    }
  }
}

describe("verifyReusableMacOSApp", () => {
  it("only reads metadata and strictly verifies the signature", async () => {
    const { app, calls } = fixture()
    await verifyReusableMacOSApp(app)
    expect(calls).toEqual([plutil, codesign])
  })

  it.each([
    [
      "missing",
      { capture: async () => Promise.reject(new Error("missing plist")) },
      /missing plist/,
      [plutil]
    ],
    [
      "foreign",
      { capture: async () => JSON.stringify({ CFBundleIdentifier: "other" }) },
      /Cannot reuse/,
      [plutil]
    ],
    [
      "wrong executable",
      {
        capture: async () =>
          JSON.stringify({ CFBundleIdentifier: "dev.example", CFBundleExecutable: "Other" })
      },
      /Cannot reuse/,
      [plutil]
    ],
    [
      "invalid signature",
      { run: async () => Promise.reject(new Error("invalid signature")) },
      /invalid signature/,
      [plutil, codesign]
    ]
  ])(
    "rejects a %s artifact without rebuilding or signing",
    async (_name, overrides, message, expectedCalls) => {
      const { app, calls } = fixture(overrides)
      await expect(verifyReusableMacOSApp(app)).rejects.toThrow(message)
      expect(calls).toEqual(expectedCalls)
    }
  )
})

describe("requestsMacOSBuildReuse", () => {
  it("is explicit and rejected by combined or iOS runners", () => {
    expect(requestsMacOSBuildReuse(["--no-ios"])).toBe(false)
    expect(requestsMacOSBuildReuse(["--no-ios", "--reuse-macos-build"])).toBe(true)
    expect(() => requestsMacOSBuildReuse(["--reuse-macos-build"])).toThrow(/only by dev:macos/)
    expect(() => parseDevelopmentRunnerArguments(["--reuse-macos-build"])).toThrow(/Unknown/)
  })
})
