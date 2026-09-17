import assert from "node:assert/strict"
import { test } from "node:test"

import {
  gallery,
  parseCaptureOptions,
  pngDimensions,
  selectedAppearances
} from "./screenshots-lib.mjs"

test("both platforms capture light and dark by default, or one explicit appearance", () => {
  for (const platform of ["ios", "macos"]) {
    const options = parseCaptureOptions([], "/checkout", platform)
    assert.equal(options.output, `/checkout/tmp/screenshots/${platform}`)
    assert.deepEqual(selectedAppearances(options), ["light", "dark"])
    for (const appearance of ["light", "dark"]) {
      assert.deepEqual(
        selectedAppearances(
          parseCaptureOptions(["--appearance", appearance], "/checkout", platform)
        ),
        [appearance]
      )
    }
    for (const args of [["--appearance", "auto"], ["--appearance"], ["--appearance", "--output"]]) {
      assert.throws(() => parseCaptureOptions(args, "/checkout", platform))
    }
  }
  assert.throws(() => parseCaptureOptions(["--runtime", "iOS 27.0"], "/checkout", "macos"))
})

test("gallery labels appearances and links original images for both platforms", () => {
  const images = ["iphone", "macos"].flatMap((device) =>
    ["light", "dark"].map((appearance) => ({
      device,
      appearance,
      scene: "01-projects",
      file: `${device}/${appearance}/01-projects.png`,
      width: 1280,
      height: 820
    }))
  )
  const html = gallery(images)
  for (const { device, appearance, file } of images) {
    assert.ok(html.includes(`href="${file}"`))
    assert.ok(html.includes(`${device} · ${appearance} · 01-projects`))
  }
})

test("macOS accepts the exact window at native display scales and rejects desktop captures", () => {
  const window = { name: "Codevisor window", width: 1280, height: 820, scales: [1, 2] }
  const bytes = Buffer.alloc(24)
  Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]).copy(bytes)
  for (const scale of window.scales) {
    bytes.writeUInt32BE(window.width * scale, 16)
    bytes.writeUInt32BE(window.height * scale, 20)
    assert.deepEqual(pngDimensions(bytes, window), {
      width: window.width * scale,
      height: window.height * scale
    })
  }
  for (const [width, height] of [
    [2560, 1600],
    [3024, 1964],
    [1280, 1640]
  ]) {
    bytes.writeUInt32BE(width, 16)
    bytes.writeUInt32BE(height, 20)
    assert.throws(() => pngDimensions(bytes, window))
  }
})
