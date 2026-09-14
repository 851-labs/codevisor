import { basename, isAbsolute, resolve } from "node:path"

export const scenes = ["01-projects", "02-conversation", "03-new-chat", "04-browser"]
export const devices = {
  iphone: {
    name: "iPhone 13 Pro Max",
    type: "com.apple.CoreSimulator.SimDeviceType.iPhone-13-Pro-Max",
    width: 1284,
    height: 2778
  },
  ipad: {
    name: "iPad Pro 13-inch (M5)",
    type: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB",
    width: 2064,
    height: 2752
  }
}

export function parseOptions(args, root) {
  const options = {
    device: "all",
    output: resolve(root, "tmp/screenshots/ios"),
    runtime: undefined
  }
  for (let index = 0; index < args.length; index++) {
    const flag = args[index]
    if (flag === "--help") return { help: true }
    if (!["--device", "--output", "--runtime"].includes(flag))
      throw new Error(`Unknown option: ${flag}`)
    const value = args[++index]
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${flag}`)
    options[flag.slice(2)] = flag === "--output" ? resolve(root, value) : value
  }
  if (!["all", ...Object.keys(devices)].includes(options.device)) {
    throw new Error("--device must be all, iphone, or ipad")
  }
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

// Select named XCTest attachments, never incidental system/failure screenshots.
export function screenshotAttachments(manifest) {
  const attachments = manifest.flatMap((test) => test.attachments)
  return scenes.map((scene) => {
    const matches = attachments.filter((attachment) => {
      const name = attachment.suggestedHumanReadableName
      return (
        !attachment.isAssociatedWithFailure &&
        (name === scene || name.startsWith(`${scene}_`) || name === `${scene}.png`)
      )
    })
    if (matches.length !== 1)
      throw new Error(`Expected one ${scene} screenshot, found ${matches.length}`)
    const filename = matches[0].exportedFileName
    if (isAbsolute(filename) || basename(filename) !== filename || !filename.endsWith(".png")) {
      throw new Error(`Invalid screenshot attachment filename: ${filename}`)
    }
    return { scene, filename }
  })
}

export function pngDimensions(bytes, device) {
  if (
    bytes.length < 24 ||
    !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  ) {
    throw new Error("Screenshot is not a PNG")
  }
  const width = bytes.readUInt32BE(16)
  const height = bytes.readUInt32BE(20)
  if (width !== device.width || height !== device.height)
    throw new Error(
      `Unexpected ${device.name} screenshot dimensions: ${width}×${height}; expected ${device.width}×${device.height}`
    )
  return { width, height }
}

export function gallery(images) {
  const cards = images
    .map(
      ({ file, device, scene, width, height }) =>
        `<a href="${file}"><img src="${file}" loading="lazy" alt="${device}: ${scene}"><p>${device} · ${scene}<br>${width} × ${height}</p></a>`
    )
    .join("\n")
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codevisor iOS screenshots</title><style>
body{margin:32px;background:#f5f5f7;color:#1d1d1f;font:15px system-ui}h1{font-size:26px}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:24px}
a{color:inherit;text-decoration:none}img{width:100%;height:560px;object-fit:contain;object-position:top;background:white;border:1px solid #ddd;border-radius:12px}p{line-height:1.5}
</style><h1>Codevisor iOS screenshots</h1><p>Actual app captures with offline demo content. Click an image for the full-resolution PNG.</p><main>${cards}</main></html>`
}
