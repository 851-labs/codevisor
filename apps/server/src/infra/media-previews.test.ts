import { execFile } from "node:child_process"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import ffmpeg from "ffmpeg-static"
import sharp from "sharp"
import { expect, it, onTestFinished } from "vitest"

import { mediaPreview } from "./media-previews.js"

it("creates bounded previews from image, video and PDF files without replacing originals", async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-previews-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  const picture = join(root, "picture.png")
  await sharp({ create: { width: 2400, height: 1600, channels: 3, background: "red" } })
    .png()
    .toFile(picture)
  const video = join(root, "clip.mp4")
  if (typeof ffmpeg !== "string") throw new Error("Missing ffmpeg binary")
  await promisify(execFile)(ffmpeg, [
    "-nostdin",
    "-loglevel",
    "error",
    "-f",
    "lavfi",
    "-i",
    "color=red:s=640x480:r=1",
    "-frames:v",
    "1",
    "-y",
    video
  ])
  const pdf = join(root, "document.pdf")
  const objects = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
    "<< /Length 27 >>\nstream\n1 0 0 rg 0 0 612 792 re f\n\nendstream"
  ]
  let source = "%PDF-1.4\n"
  const offsets = [0]
  for (const [index, body] of objects.entries()) {
    offsets.push(Buffer.byteLength(source))
    source += `${index + 1} 0 obj\n${body}\nendobj\n`
  }
  const xref = Buffer.byteLength(source)
  source += `xref\n0 5\n0000000000 65535 f \n${offsets
    .slice(1)
    .map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`)
    .join("")}trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF\n`
  await writeFile(pdf, source)
  for (const [path, type] of [
    [picture, "image/png"],
    [video, "video/mp4"],
    [pdf, "application/pdf"]
  ] as const) {
    const preview = await mediaPreview(path, type, root, path)
    expect(preview.length).toBeLessThan(1024 * 1024)
    const metadata = await sharp(preview).metadata()
    expect(metadata.width).toBeLessThanOrEqual(480)
    expect(metadata.height).toBeLessThanOrEqual(480)
    expect(await mediaPreview(path, type, root, path)).toEqual(preview)
  }
  expect((await sharp(picture).metadata()).width).toBe(2400)
})
