import { spawn } from "node:child_process"
import { createHash, randomUUID } from "node:crypto"
import { mkdir, readFile, rename, rm, stat } from "node:fs/promises"
import { extname, join } from "node:path"
import { Worker } from "node:worker_threads"

import ffmpeg from "ffmpeg-static"
import sharp from "sharp"

import { trimMediaPreviewCache } from "./media-preview-cache.js"

const inFlight = new Map<string, Promise<Buffer>>()
const waiters: Array<() => void> = []
let active = 0

const acquire = async (): Promise<void> => {
  if (active < 2) {
    active += 1
    return
  }
  if (waiters.length >= 64) throw new Error("Media preview queue is full")
  await new Promise<void>((resolve) => waiters.push(resolve))
}
const release = (): void => {
  const next = waiters.shift()
  if (next === undefined) active -= 1
  else next()
}

const videoFrame = (path: string, output: string): Promise<void> =>
  new Promise((resolve, reject) => {
    if (typeof ffmpeg !== "string") {
      reject(new Error("Video preview encoder is unavailable"))
      return
    }
    const child = spawn(
      ffmpeg,
      [
        "-nostdin",
        "-hide_banner",
        "-loglevel",
        "error",
        "-max_alloc",
        "67108864",
        "-protocol_whitelist",
        "file,pipe",
        "-threads",
        "1",
        "-i",
        path,
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
        "-filter_threads",
        "1",
        "-vf",
        "scale=480:480:force_original_aspect_ratio=decrease",
        "-vcodec",
        "png",
        "-compression_level",
        "3",
        "-f",
        "image2",
        "-y",
        output
      ],
      { stdio: ["ignore", "ignore", "pipe"] }
    )
    let detail = ""
    child.stderr.on("data", (chunk) => {
      detail = (detail + String(chunk)).slice(-2048)
    })
    const timeout = setTimeout(() => child.kill("SIGKILL"), 30_000)
    timeout.unref()
    child.once("error", (error) => {
      clearTimeout(timeout)
      reject(error)
    })
    child.once("close", (code) => {
      clearTimeout(timeout)
      if (code === 0) resolve()
      else reject(new Error(`Unable to create video preview: ${detail}`))
    })
  })

/** Immutable previews are separate from originals. Decoders work on files,
 * with at most two jobs active; original videos never enter Node buffers. */
export const mediaPreview = async (
  path: string,
  mimeType: string,
  cacheRoot: string,
  version: string
): Promise<Buffer> => {
  const key = createHash("sha256").update(`480-v1:${version}`).digest("hex")
  const folder = join(cacheRoot, "previews")
  const target = join(folder, `${key}.png`)
  try {
    return await readFile(target)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error
  }
  const existing = inFlight.get(target)
  if (existing !== undefined) return existing
  const task = (async () => {
    await acquire()
    const temporary = join(folder, `${key}.${randomUUID()}.png`)
    try {
      await mkdir(folder, { recursive: true, mode: 0o700 })
      if (mimeType === "application/pdf") await pdfFrame(path, temporary)
      else if (mimeType.startsWith("video/")) await videoFrame(path, temporary)
      else
        await sharp(path, { limitInputPixels: 100_000_000, sequentialRead: true, pages: 1 })
          .rotate()
          .resize(480, 480, { fit: "inside", withoutEnlargement: true })
          .png()
          .toFile(temporary)
      const info = await stat(temporary)
      if (info.size > 1024 * 1024) throw new Error("Media preview exceeds its size limit")
      await rename(temporary, target)
      const data = await readFile(target)
      await trimMediaPreviewCache(folder)
      return data
    } finally {
      try {
        await rm(temporary, { force: true })
      } finally {
        release()
      }
    }
  })()
  inFlight.set(target, task)
  try {
    return await task
  } finally {
    inFlight.delete(target)
  }
}

const pdfFrame = (path: string, output: string): Promise<void> =>
  new Promise((resolve, reject) => {
    const worker = new Worker(
      new URL(`./pdf-preview-worker${extname(new URL(import.meta.url).pathname)}`, import.meta.url),
      {
        workerData: { path, output },
        resourceLimits: { maxOldGenerationSizeMb: 192 }
      }
    )
    const timer = setTimeout(() => {
      void worker.terminate()
      reject(new Error("PDF preview timed out"))
    }, 30_000)
    timer.unref()
    worker.once("error", (error) => {
      clearTimeout(timer)
      reject(error)
    })
    worker.once("exit", (code) => {
      clearTimeout(timer)
      if (code === 0) resolve()
      else reject(new Error(`PDF preview worker exited (${code})`))
    })
  })
