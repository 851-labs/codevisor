import assert from "node:assert/strict"
import test from "node:test"

import { frameClockReport, parseFrameClockArguments } from "./vnc-frame-clock-lib.ts"

test("vnc:frame-clock defaults to the rig and Apple Screen Sharing and validates options (851-2358)", () => {
  assert.deepEqual(parseFrameClockArguments([]), {
    apps: ["com.codevisor.ScreenSharingRig", "com.apple.ScreenSharing"],
    seconds: 60,
    mode: "video",
    port: 8765
  })
  assert.deepEqual(
    parseFrameClockArguments([
      "--app",
      "a",
      "--seconds",
      "20",
      "--mode",
      "scroll",
      "--port",
      "9000",
      "--out",
      "/x",
      "--label",
      "L"
    ]),
    { apps: ["a"], seconds: 20, mode: "scroll", port: 9000, out: "/x", label: "L" }
  )
  assert.equal(parseFrameClockArguments(["--help"]), "help")
  assert.throws(() => parseFrameClockArguments(["--mode", "fast"]), /--mode is one of/)
  assert.throws(() => parseFrameClockArguments(["--seconds", "0"]), /positive/)
  assert.throws(() => parseFrameClockArguments(["--seconds"]), /needs a value/)
  assert.throws(() => parseFrameClockArguments(["--bogus", "1"]), /unknown option/)
})

test("vnc:frame-clock reports each viewer and only the positive lags", () => {
  const report = frameClockReport(
    {
      seconds: 60,
      apps: {
        "com.codevisor.ScreenSharingRig": {
          window: "1431x817",
          updatesPerSecond: 0.64,
          hostFramesShown: 0.01,
          gapP50Ms: 1392.2,
          gapP95Ms: 2430.4,
          gapMaxMs: 5636.6,
          tornFraction: 0,
          unreadableFraction: 0
        },
        "com.example.Other": {}
      },
      lags: {
        "com.codevisor.ScreenSharingRig behind com.apple.ScreenSharing": {
          p50Ms: 917,
          p95Ms: 2217
        },
        "com.apple.ScreenSharing behind com.codevisor.ScreenSharingRig": { p50Ms: -917, p95Ms: -67 }
      }
    },
    { mode: "video", label: "baseline" }
  )
  assert.match(report, /# Frame clock — baseline/)
  assert.ok(
    report.includes("| Codevisor rig | 1431x817 | 0.64 | 1% | 1392 | 2430 | 5637 | 0% | 0% |")
  )
  assert.ok(report.includes("| com.example.Other | – | – | – | – | – | – | – | – |"))
  assert.ok(report.includes("| Codevisor rig behind Apple Screen Sharing | 917 | 2217 |"))
  assert.ok(!report.includes("-917"))
  assert.ok(
    !frameClockReport({ seconds: 5, apps: {}, lags: {} }, { mode: "still" }).includes("| lag |")
  )
})
