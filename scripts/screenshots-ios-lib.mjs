import { execFile, spawn } from "node:child_process"
import { once } from "node:events"
import { createInterface } from "node:readline"
import { promisify } from "node:util"

import { waitForExit } from "./dev-shared.mjs"
import { parseCaptureOptions } from "./screenshots-lib.mjs"

const execute = promisify(execFile)
const statusBarTime = new Date(2001, 7, 8, 14, 5).toISOString()

export const iosScenes = [
  "01-bots",
  "02-bot-conversation",
  "03-mascot-editor",
  "04-projects",
  "05-conversation",
  "06-new-chat",
  "07-browser"
]

const ipadScenes = ["01-bot-conversation", "02-conversation", "03-mascot-editor", "04-browser"]

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
    minimumSdk: "27.1"
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

export async function startMascotServer(root) {
  const child = spawn(
    process.execPath,
    ["--conditions=@codevisor/source", "scripts/screenshots-mascot-server.mjs"],
    { cwd: root, stdio: ["ignore", "pipe", "inherit"] }
  )
  const exit = waitForExit(child)
  const started = await Promise.race([
    once(createInterface({ input: child.stdout }), "line"),
    exit.then(() => undefined)
  ])
  if (started === undefined) throw new Error("The mascot art server exited before it started")
  const [url] = started
  return {
    url,
    async stop() {
      child.kill()
      await exit
    }
  }
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
