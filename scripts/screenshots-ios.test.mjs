import assert from "node:assert/strict"
import { test } from "node:test"

import {
  devices,
  appStoreJobs,
  isDarkBitmap,
  parseOptions,
  selectRuntime
} from "./screenshots-ios-lib.mjs"
import { pngDimensions, scenes, screenshotAttachments } from "./screenshots-lib.mjs"

test("options stay rooted in this checkout and reject missing or unknown arguments", () => {
  assert.equal(parseOptions([], "/checkout").output, "/checkout/tmp/screenshots/ios")
  assert.equal(parseOptions([], "/checkout").device, "iphone")
  assert.equal(parseOptions(["--device", "ipad-pro-11"], "/checkout").device, "ipad-pro-11")
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
    ["--device", "all"],
    ["--device", "mac"],
    ["--output"],
    ["--device", "--output"],
    ["--upload"]
  ]) {
    assert.throws(() => parseOptions(args, "/checkout"))
  }
})

const runtime = (version, supported = Object.values(devices), isAvailable = true) => ({
  name: `iOS ${version}`,
  identifier: `com.apple.CoreSimulator.SimRuntime.iOS-${version.replaceAll(".", "-")}`,
  version,
  isAvailable,
  supportedDeviceTypes: supported.map(({ type }) => ({ identifier: type }))
})

test("runtime selection requires supported devices and ignores unavailable runtimes", () => {
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
  bytes.writeUInt32BE(1284, 16)
  bytes.writeUInt32BE(2778, 20)
  assert.deepEqual(pngDimensions(bytes, devices.iphone), {
    width: 1284,
    height: 2778
  })
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

test("an unfolded iPhone Duo is detected from any lit pixel on its inner display", () => {
  const headerSize = 54
  const bitmap = Buffer.alloc(headerSize + 4 * 4)
  bitmap.writeUInt32LE(headerSize, 10)
  bitmap.writeUInt16LE(32, 28)
  for (let pixel = 0; pixel < 4; pixel++) bitmap[headerSize + pixel * 4 + 3] = 255
  assert.equal(isDarkBitmap(bitmap), true)
  bitmap[headerSize + 2 * 4 + 1] = 12
  assert.equal(isDarkBitmap(bitmap), false)
})

test("each App Store scene yields a plain and a framed screenshot at a size App Store Connect accepts", () => {
  const accepted = {
    iphone: ["1206x2622"],
    ipad: ["2752x2064"],
    "iphone-duo": ["2853x2007"]
  }
  const jobs = appStoreJobs("/captures", "/out")
  for (const job of jobs) {
    const [, , set, slot] = job.output.split("/")
    assert.ok(
      accepted[slot].includes(`${job.width}x${job.height}`),
      `${job.output} is ${job.width}x${job.height}`
    )
    if (set === "app-store-screenshots-framed") {
      assert.ok(job.caption && job.device, `${job.output} has no frame or caption`)
      assert.match(job.input, /-dark\.png$/)
    } else {
      assert.equal(job.caption, undefined)
      assert.match(job.input, /-light\.png$/)
    }
  }
  assert.equal(new Set(jobs.map((job) => job.output)).size, jobs.length)
  const names = (set, slot) =>
    jobs
      .filter((job) => job.output.startsWith(`/out/${set}/${slot}/`))
      .map((job) => job.output.split("/").at(-1))
  for (const set of ["app-store-screenshots", "app-store-screenshots-framed"]) {
    assert.deepEqual(names(set, "iphone"), [
      "01-projects.png",
      "02-conversation.png",
      "03-harnesses.png",
      "04-updates.png"
    ])
    assert.deepEqual(names(set, "ipad"), [
      "01-conversation.png",
      "02-harnesses.png",
      "03-updates.png"
    ])
    assert.deepEqual(names(set, "iphone-duo"), [
      "01-conversation.png",
      "02-harnesses.png",
      "03-updates.png"
    ])
  }
})
