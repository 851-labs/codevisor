import assert from "node:assert/strict"
import { test } from "node:test"

import { devices, parseOptions, selectRuntime } from "./screenshots-ios-lib.mjs"
import { pngDimensions, scenes, screenshotAttachments } from "./screenshots-lib.mjs"

test("options stay rooted in this checkout and reject missing or unknown arguments", () => {
  assert.equal(parseOptions([], "/checkout").output, "/checkout/tmp/screenshots/ios")
  assert.equal(parseOptions([], "/checkout").device, "iphone")
  assert.equal(parseOptions(["--device", "all"], "/checkout").device, "all")
  assert.deepEqual(
    parseOptions(
      ["--device", "iphone", "--output", "captures", "--runtime", "iOS 27.0"],
      "/checkout"
    ),
    {
      device: "iphone",
      output: "/checkout/captures",
      runtime: "iOS 27.0",
      appearance: "all"
    }
  )
  for (const args of [
    ["--device", "ipad"],
    ["--device", "mac"],
    ["--output"],
    ["--device", "--output"],
    ["--upload"]
  ]) {
    assert.throws(() => parseOptions(args, "/checkout"))
  }
})

test("runtime selection requires supported devices and ignores unavailable runtimes", () => {
  const runtime = (version, supported = Object.values(devices), isAvailable = true) => ({
    name: `iOS ${version}`,
    identifier: `com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll(".", "-")}`,
    version,
    isAvailable,
    supportedDeviceTypes: supported.map(({ type }) => ({ identifier: type }))
  })
  const candidates = [
    runtime("26.2"),
    runtime("26.10"),
    runtime("27.0", []),
    runtime("28.0", undefined, false)
  ]
  assert.equal(selectRuntime(candidates, Object.values(devices)).version, "26.10")
  assert.equal(selectRuntime(candidates, Object.values(devices), "iOS 26.2").version, "26.2")
  assert.throws(() => selectRuntime(candidates, Object.values(devices), "iOS 27.0"))
  assert.throws(() => selectRuntime(candidates, Object.values(devices), "iOS 28.0"))
})

const attachments = () =>
  scenes.map((scene, index) => ({
    suggestedHumanReadableName: `${scene}_1.png`,
    exportedFileName: `${index}.png`,
    isAssociatedWithFailure: false
  }))

test("export selects exactly the named captures and rejects missing or ambiguous results", () => {
  const valid = attachments()
  assert.deepEqual(
    screenshotAttachments([
      {
        attachments: [
          ...valid,
          {
            suggestedHumanReadableName: "automatic-screenshot.png",
            exportedFileName: "extra.png",
            isAssociatedWithFailure: false
          }
        ]
      }
    ]).map(({ scene }) => scene),
    scenes
  )
  assert.throws(() => screenshotAttachments([{ attachments: valid.slice(1) }]))
  assert.throws(() => screenshotAttachments([{ attachments: [...valid, valid[0]] }]))
  valid[0].isAssociatedWithFailure = true
  assert.throws(() => screenshotAttachments([{ attachments: valid }]))
})

test("export cannot read an attachment outside its result directory", () => {
  for (const filename of ["../secret.png", "/tmp/secret.png", "image.txt"]) {
    const invalid = attachments()
    invalid[0].exportedFileName = filename
    assert.throws(() => screenshotAttachments([{ attachments: invalid }]))
  }
})

test("export requires the exact dimensions for each App Store screenshot slot", () => {
  const bytes = Buffer.alloc(24)
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes)
  for (const device of Object.values(devices)) {
    bytes.writeUInt32BE(device.width, 16)
    bytes.writeUInt32BE(device.height, 20)
    assert.deepEqual(pngDimensions(bytes, device), { width: device.width, height: device.height })
  }
  // The former 6.9-inch captures are not accepted in the 6.5-inch slot.
  for (const [width, height] of [
    [2064, 2752],
    [1320, 2868],
    [2778, 1284],
    [400, 800]
  ]) {
    bytes.writeUInt32BE(width, 16)
    bytes.writeUInt32BE(height, 20)
    assert.throws(() => pngDimensions(bytes, devices.iphone))
  }
  assert.throws(() => pngDimensions(Buffer.from("not a screenshot"), devices.iphone))
})
