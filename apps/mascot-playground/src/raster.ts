import { withPixelSize } from "./svg-text.js"

export async function svgImage(svg: string, pixels: number): Promise<HTMLImageElement> {
  const url = URL.createObjectURL(new Blob([withPixelSize(svg, pixels)], { type: svgType }))
  const image = new Image()
  image.src = url
  try {
    await image.decode()
    return image
  } finally {
    URL.revokeObjectURL(url)
  }
}

export async function downloadPng(svg: string, pixels: number, name: string): Promise<void> {
  const canvas = document.createElement("canvas")
  canvas.width = pixels
  canvas.height = pixels
  canvas.getContext("2d")?.drawImage(await svgImage(svg, pixels), 0, 0)
  const blob = await new Promise<Blob | null>((done) => canvas.toBlob(done, "image/png"))
  if (blob) download(blob, `${name}.png`)
}

export const downloadSvg = (svg: string, name: string): void =>
  download(new Blob([svg], { type: svgType }), `${name}.svg`)

const svgType = "image/svg+xml"
const revokeDelayMs = 1000

function download(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob)
  const link = document.createElement("a")
  link.href = url
  link.download = filename
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), revokeDelayMs)
}
