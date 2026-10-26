import { execFile } from "node:child_process"
import { promisify } from "node:util"

import { parseCaptureOptions } from "./screenshots-lib.mjs"

const execute = promisify(execFile)
const statusBarTime = new Date(2001, 7, 8, 14, 5).toISOString()

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
  "ipad-pro-11": {
    name: "iPad Pro 11-inch (M5)",
    type: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB",
    width: 1668,
    height: 2420,
    orientation: "landscape",
    scenes: ["02-conversation"]
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
