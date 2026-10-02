import { describe, expect, it } from "vitest"

import {
  chromeImageNames,
  parseDisplays,
  parseFeatures,
  parseSimulatorList
} from "./simulator-parsing.js"

const runtime = (suffix: string) => `com.apple.CoreSimulator.SimRuntime.${suffix}`
const udid = (n: number) => `00000000-0000-4000-8000-00000000000${n}`

describe("simulator list parsing", () => {
  it("fills in what simctl leaves out", () => {
    const parsed = parseSimulatorList({
      devicetypes: [
        { identifier: "phone", name: "iPhone 17" },
        { name: "No identifier" },
        { identifier: "no-name" }
      ],
      runtimes: [
        { identifier: runtime("iOS-26-0") },
        { identifier: runtime("xrOS-2-0"), supportedDeviceTypes: [{ identifier: "phone" }, {}] },
        { name: "No identifier" }
      ],
      devices: {
        [runtime("iOS-26-0")]: [{ udid: udid(1) }, { name: "No id" }],
        [runtime("xrOS-2-0")]: [
          {
            udid: udid(2),
            name: "Vision",
            deviceTypeIdentifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro",
            lastBootedAt: "2026-10-01T00:00:00Z"
          }
        ]
      }
    })
    expect(parsed.deviceTypes).toEqual([
      { identifier: "phone", name: "iPhone 17", productFamily: "iPhone" }
    ])
    expect(parsed.runtimes).toEqual([
      {
        identifier: runtime("iOS-26-0"),
        name: runtime("iOS-26-0"),
        platform: "iOS",
        version: "",
        deviceTypeIdentifiers: []
      },
      {
        identifier: runtime("xrOS-2-0"),
        name: runtime("xrOS-2-0"),
        platform: "xrOS",
        version: "",
        deviceTypeIdentifiers: ["phone"]
      }
    ])
    expect(parsed.devices).toEqual([
      {
        udid: udid(1),
        name: "Simulator",
        state: "Shutdown",
        runtime: {
          identifier: runtime("iOS-26-0"),
          name: runtime("iOS-26-0"),
          platform: "iOS",
          version: ""
        },
        deviceType: { identifier: "", name: "", productFamily: "iPhone" }
      },
      {
        udid: udid(2),
        name: "Vision",
        state: "Shutdown",
        runtime: {
          identifier: runtime("xrOS-2-0"),
          name: runtime("xrOS-2-0"),
          platform: "xrOS",
          version: ""
        },
        // An unknown type keeps its identifier and takes the last part as its name.
        deviceType: {
          identifier: "com.apple.CoreSimulator.SimDeviceType.Apple-Vision-Pro",
          name: "Apple-Vision-Pro",
          productFamily: "iPhone"
        },
        lastBootedAt: "2026-10-01T00:00:00Z"
      }
    ])
  })

  it("orders devices by family, then name, then newest OS first", () => {
    const types = [
      { identifier: "phone", name: "iPhone", productFamily: "iPhone" },
      { identifier: "pad", name: "iPad", productFamily: "iPad" },
      { identifier: "car", name: "CarPlay", productFamily: "CarPlay" }
    ]
    const parsed = parseSimulatorList({
      devicetypes: types,
      runtimes: [
        { identifier: runtime("iOS-26-0"), version: "26.0" },
        { identifier: runtime("iOS-27-0"), version: "27.0" }
      ],
      devices: {
        [runtime("iOS-26-0")]: [
          { udid: udid(1), name: "Car", deviceTypeIdentifier: "car" },
          { udid: udid(2), name: "Phone", deviceTypeIdentifier: "phone" },
          { udid: udid(3), name: "Pad 10", deviceTypeIdentifier: "pad" }
        ],
        [runtime("iOS-27-0")]: [
          { udid: udid(4), name: "Phone", deviceTypeIdentifier: "phone" },
          { udid: udid(5), name: "Pad 9", deviceTypeIdentifier: "pad" },
          { udid: udid(6), name: "Gone", deviceTypeIdentifier: "phone", isAvailable: false }
        ]
      }
    })
    expect(parsed.devices.map((device) => `${device.name} ${device.runtime.version}`)).toEqual([
      "Phone 27.0",
      "Phone 26.0",
      "Pad 9 27.0",
      "Pad 10 26.0",
      "Car 26.0"
    ])
  })

  it("reads nothing from an empty list", () => {
    expect(parseSimulatorList({})).toEqual({ devices: [], deviceTypes: [], runtimes: [] })
  })
})

describe("device type parsing", () => {
  it("defaults a display's name, scale and corners, and skips unsized ones", () => {
    expect(parseDisplays({ displays: [] }, new Map())).toEqual([])
    expect(
      parseDisplays(
        [
          { displayType: "integrated", width: 100, height: Number.NaN },
          {
            displayType: "integrated",
            width: 390,
            height: 844,
            framebufferMaskIdentifier: "Missing"
          }
        ],
        new Map()
      )
    ).toEqual([
      {
        name: "primary",
        width: 390,
        height: 844,
        scale: 1,
        cornerRadii: [0, 0, 0, 0],
        hasDigitizer: false
      }
    ])
  })

  it("collects the features a profile turns on, conditional ones included", () => {
    expect(
      parseFeatures({
        supportedFeatures: { "com.apple.b": true, "com.apple.off": false, "com.apple.a": "1" },
        supportedFeaturesConditionalOnRuntime: { "com.apple.c": true, "com.apple.a": true }
      })
    ).toEqual(["com.apple.a", "com.apple.b", "com.apple.c"])
    expect(
      parseFeatures({ supportedFeatures: null, supportedFeaturesConditionalOnRuntime: 3 })
    ).toEqual([])
  })

  it("names the chrome images it may load, and no paths", () => {
    expect(
      chromeImageNames({
        images: { frame: "PhoneFrame", count: 3, escape: "../../etc/passwd" },
        inputs: [{ image: "VolumeUp", imageDown: "VolumeUpDown" }, { image: 4 }]
      })
    ).toEqual(["PhoneFrame", "VolumeUp", "VolumeUpDown"])
    expect(chromeImageNames({})).toEqual([])
  })
})
