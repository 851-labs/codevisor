import assert from "node:assert/strict"
import test from "node:test"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.mjs"
import { requestsMacOSBuildReuse, verifyReusableMacOSApp } from "./dev-macos-reuse.mjs"

function fixture(overrides = {}) {
  const calls = []
  const capture =
    overrides.capture ??
    (async () =>
      JSON.stringify({ CFBundleIdentifier: "dev.example", CFBundleExecutable: "Example" }))
  const run = overrides.run ?? (async () => undefined)
  return {
    calls,
    options: {
      appBundle: "/owned/Debug/Example.app",
      bundleIdentifier: "dev.example",
      executableName: "Example",
      capture: async (command, args) => {
        calls.push([command, ...args])
        return capture(command, args)
      },
      run: async (command, args) => {
        calls.push([command, ...args])
        return run(command, args)
      }
    }
  }
}

test("reuse performs only metadata reading and strict signature verification", async () => {
  const { options, calls } = fixture()
  await verifyReusableMacOSApp(options)
  assert.deepEqual(calls, [
    [
      "/usr/bin/plutil",
      "-convert",
      "json",
      "-o",
      "-",
      "/owned/Debug/Example.app/Contents/Info.plist"
    ],
    ["/usr/bin/codesign", "--verify", "--deep", "--strict", "/owned/Debug/Example.app"]
  ])
})

for (const [name, overrides, message] of [
  [
    "missing",
    {
      capture: async () => {
        throw new Error("missing plist")
      }
    },
    /missing plist/
  ],
  [
    "foreign",
    { capture: async () => JSON.stringify({ CFBundleIdentifier: "other" }) },
    /Cannot reuse/
  ],
  [
    "wrong executable",
    {
      capture: async () =>
        JSON.stringify({ CFBundleIdentifier: "dev.example", CFBundleExecutable: "Other" })
    },
    /Cannot reuse/
  ],
  [
    "invalid signature",
    {
      run: async () => {
        throw new Error("invalid signature")
      }
    },
    /invalid signature/
  ]
]) {
  test(`${name} artifact rejects reuse without a rebuild or signing command`, async () => {
    const { options, calls } = fixture(overrides)
    await assert.rejects(verifyReusableMacOSApp(options), message)
    assert.deepEqual(calls, [
      [
        "/usr/bin/plutil",
        "-convert",
        "json",
        "-o",
        "-",
        "/owned/Debug/Example.app/Contents/Info.plist"
      ],
      ...(name === "invalid signature"
        ? [["/usr/bin/codesign", "--verify", "--deep", "--strict", "/owned/Debug/Example.app"]]
        : [])
    ])
  })
}

test("reuse is explicit and rejected by combined or iOS runners", () => {
  assert.equal(requestsMacOSBuildReuse(["--no-ios"]), false)
  assert.equal(requestsMacOSBuildReuse(["--no-ios", "--reuse-macos-build"]), true)
  assert.throws(() => requestsMacOSBuildReuse(["--reuse-macos-build"]), /only by dev:macos/)
  assert.throws(() => parseDevelopmentRunnerArguments(["--reuse-macos-build"]), /Unknown/)
})
