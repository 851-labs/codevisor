import { basename, isAbsolute, resolve } from "node:path"

export const scenes = ["01-projects", "02-conversation", "03-new-chat", "04-browser"]
export const appearances = ["light", "dark"]

export function parseCaptureOptions(args, root, platform) {
  const options = {
    output: resolve(root, `tmp/screenshots/${platform}`),
    appearance: "all",
    ...(platform === "ios" ? { device: "iphone", runtime: undefined } : {})
  }
  const flags = [
    "--output",
    "--appearance",
    ...(platform === "ios" ? ["--device", "--runtime"] : [])
  ]
  for (let index = 0; index < args.length; index++) {
    const flag = args[index]
    if (flag === "--help") return { help: true }
    if (!flags.includes(flag)) throw new Error(`Unknown option: ${flag}`)
    const value = args[++index]
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${flag}`)
    options[flag.slice(2)] = flag === "--output" ? resolve(root, value) : value
  }
  if (!["all", ...appearances].includes(options.appearance))
    throw new Error("--appearance must be all, light, or dark")
  return options
}

export function selectedAppearances(options) {
  return appearances.filter(
    (appearance) => options.appearance === "all" || options.appearance === appearance
  )
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
  const expected = (device.scales ?? [1]).map((scale) => ({
    width: device.width * scale,
    height: device.height * scale
  }))
  if (!expected.some((size) => width === size.width && height === size.height))
    throw new Error(
      `Unexpected ${device.name} screenshot dimensions: ${width}×${height}; expected ${expected.map((size) => `${size.width}×${size.height}`).join(" or ")}`
    )
  return { width, height }
}

export function gallery(images) {
  const cards = images
    .map(
      ({ file, device, scene, appearance, width, height }) =>
        `<a href="${file}"><img src="${file}" loading="lazy" alt="${device}: ${appearance} ${scene}"><p>${device} · ${appearance} · ${scene}<br>${width} × ${height}</p></a>`
    )
    .join("\n")
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Codevisor marketing screenshots</title><style>
body{margin:32px;background:#f5f5f7;color:#1d1d1f;font:15px system-ui}h1{font-size:26px}
main{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:24px}
a{color:inherit;text-decoration:none}img{width:100%;height:560px;object-fit:contain;object-position:top;background:white;border:1px solid #ddd;border-radius:12px}p{line-height:1.5}
</style><h1>Codevisor marketing screenshots</h1><p>Actual app captures with offline demo content. Click an image for the full-resolution PNG.</p><main>${cards}</main></html>`
}
