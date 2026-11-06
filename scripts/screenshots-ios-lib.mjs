import { execFile } from "node:child_process"
import { promisify } from "node:util"

import { parseCaptureOptions } from "./screenshots-lib.mjs"

const execute = promisify(execFile)
const statusBarTime = new Date(2001, 7, 8, 14, 5).toISOString()

export const iosScenes = ["01-projects", "02-conversation", "03-harnesses", "04-updates"]

const ipadScenes = ["01-conversation", "02-harnesses", "03-updates"]

export const devices = {
  iphone: {
    name: "iPhone 13 Pro Max",
    type: "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max",
    width: 1284,
    height: 2778
  },
  "iphone-18-pro": {
    name: "iPhone 18 Pro",
    type: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
    width: 1206,
    height: 2622
  },
  "iphone-duo": {
    name: "iPhone Duo",
    type: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
    width: 1398,
    height: 2034,
    display: "1",
    minimumSdk: "27.1",
    scenes: ["01-projects", "02-conversation", "03-harnesses"]
  },
  "iphone-duo-unfolded": {
    name: "iPhone Duo",
    type: "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo",
    width: 2853,
    height: 2007,
    display: "3",
    minimumSdk: "27.1",
    unfolded: true,
    scenes: ["01-conversation", "02-harnesses"]
  },
  "ipad-pro-11": {
    name: "iPad Pro 11-inch (M5)",
    type: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB",
    width: 1668,
    height: 2420,
    orientation: "landscape",
    scenes: ipadScenes
  },
  "ipad-pro-13": {
    name: "iPad Pro 13-inch (M5)",
    type: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    width: 2064,
    height: 2752,
    orientation: "landscape",
    scenes: ipadScenes
  }
}

export function parseOptions(args, root) {
  const options = parseCaptureOptions(args, root, "ios")
  if (options.help) return options
  if (!Object.hasOwn(devices, options.device))
    throw new Error(`--device must be one of ${Object.keys(devices).join(", ")}`)
  return options
}

export function selectRuntime(runtimes, selectedDevices, requested) {
  const compatible = runtimes.filter(
    (runtime) =>
      runtime.isAvailable &&
      runtime.identifier.includes(".iOS-") &&
      selectedDevices.every((device) =>
        runtime.supportedDeviceTypes.some((type) => type.identifier === device.type)
      ) &&
      (!requested || runtime.identifier === requested || runtime.name === requested)
  )
  compatible.sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))
  if (!compatible[0])
    throw new Error(
      "No compatible iOS Simulator runtime. Install one in Xcode Settings → Components."
    )
  return compatible[0]
}

export async function simctl(...args) {
  return (
    await execute("xcrun", ["simctl", ...args], { maxBuffer: 16 * 1024 * 1024 })
  ).stdout.trim()
}

export async function prepareThrowawaySimulator(udid) {
  await bootSimulator(udid)
  await simctl("spawn", udid, "defaults", "write", "-g", "AppleICUForce24HourTime", "-bool", "YES")
  await simctl("shutdown", udid)
  await bootSimulator(udid)
  await simctl(
    "status_bar",
    udid,
    "override",
    "--dataNetwork",
    "wifi",
    "--wifiMode",
    "active",
    "--wifiBars",
    "3",
    "--batteryState",
    "discharging",
    "--batteryLevel",
    "100"
  )
  await simctl("status_bar", udid, "override", "--time", statusBarTime)
}

async function bootSimulator(udid) {
  await simctl("boot", udid)
  await simctl("bootstatus", udid, "-b")
}

export async function requireSimulatorSdk(device) {
  if (device.minimumSdk === undefined) return
  const { stdout } = await execute("xcrun", ["--sdk", "iphonesimulator", "--show-sdk-version"])
  const version = stdout.trim()
  if (version.localeCompare(device.minimumSdk, undefined, { numeric: true }) < 0)
    throw new Error(
      `${device.name} screenshots need the iOS ${device.minimumSdk} SDK or later, but this Xcode builds with ${version}. Set DEVELOPER_DIR to a newer Xcode.`
    )
}

export function isDarkBitmap(bytes) {
  const pixels = bytes.subarray(bytes.readUInt32LE(10))
  const bytesPerPixel = bytes.readUInt16LE(28) / 8
  for (let index = 0; index < pixels.length; index += bytesPerPixel) {
    if (pixels[index] || pixels[index + 1] || pixels[index + 2]) return false
  }
  return true
}
