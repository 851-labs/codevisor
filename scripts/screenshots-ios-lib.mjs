import { parseCaptureOptions } from "./screenshots-lib.mjs"

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
  if (!["all", ...Object.keys(devices)].includes(options.device))
    throw new Error(`--device must be all or one of ${Object.keys(devices).join(", ")}`)
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
