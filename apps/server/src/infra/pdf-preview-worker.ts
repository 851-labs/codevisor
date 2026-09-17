import { writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { workerData } from "node:worker_threads"

import { createCanvas } from "@napi-rs/canvas"
import { getDocument } from "pdfjs-dist/legacy/build/pdf.mjs"

const { path, output } = workerData as { path: string; output: string }
const packageRoot = dirname(fileURLToPath(import.meta.resolve("pdfjs-dist/package.json")))
const task = getDocument({
  url: path,
  disableStream: true,
  disableAutoFetch: true,
  rangeChunkSize: 65_536,
  maxImageSize: 16_000_000,
  canvasMaxAreaInBytes: 16 * 1024 * 1024,
  useSystemFonts: false,
  standardFontDataUrl: `${join(packageRoot, "standard_fonts")}/`
})
try {
  const pdf = await task.promise
  const page = await pdf.getPage(1)
  const natural = page.getViewport({ scale: 1 })
  const viewport = page.getViewport({
    scale: Math.min(1, 480 / Math.max(natural.width, natural.height))
  })
  const canvas = createCanvas(
    Math.max(1, Math.ceil(viewport.width)),
    Math.max(1, Math.ceil(viewport.height))
  )
  await page.render({ canvas: canvas as unknown as HTMLCanvasElement, viewport }).promise
  await writeFile(output, await canvas.encode("png"))
} finally {
  await task.destroy()
}
