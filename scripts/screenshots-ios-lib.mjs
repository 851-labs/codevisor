import { parseCaptureOptions } from "./screenshots-lib.mjs"
export { scenes, gallery, pngDimensions, screenshotAttachments } from "./screenshots-lib.mjs"

export const devices = {
  iphone: {
    name: "iPhone 13 Pro Max",
    type: "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max",
    width: 1284,
    height: 2778
  }
}

export function parseOptions(args, root) {
  const options = parseCaptureOptions(args, root, "ios")
  if (options.help) return options
  if (!["all", ...Object.keys(devices)].includes(options.device))
    throw new Error("--device must be all or iphone (iPad support is disabled)")
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
