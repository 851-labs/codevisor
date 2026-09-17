import { EventEmitter } from "node:events"

import { beforeEach, expect, it, vi } from "vitest"
const mocks = vi.hoisted(() => ({
  readFile: vi.fn(),
  stat: vi.fn(),
  mkdir: vi.fn(),
  rename: vi.fn(),
  rm: vi.fn(),
  render: vi.fn(),
  spawn: vi.fn(),
  worker: vi.fn(),
  encoder: { value: "/ffmpeg" as string | null }
}))
vi.mock("node:fs/promises", () => mocks)
vi.mock("node:child_process", () => ({ spawn: mocks.spawn }))
vi.mock("node:worker_threads", () => ({
  Worker: vi.fn(function (...args: unknown[]) {
    return mocks.worker(...args)
  })
}))
vi.mock("ffmpeg-static", () => ({
  get default() {
    return mocks.encoder.value
  }
}))
vi.mock("./media-preview-cache.js", () => ({ trimMediaPreviewCache: vi.fn() }))
vi.mock("sharp", () => ({
  default: () => {
    const image = {
      rotate: () => image,
      resize: () => image,
      png: () => image,
      toFile: mocks.render
    }
    return image
  }
}))

beforeEach(() => {
  vi.resetModules()
  vi.resetAllMocks()
  mocks.encoder.value = "/ffmpeg"
  const saved = new Set<string>()
  mocks.readFile.mockImplementation(async (path: string) => {
    if (saved.has(path)) return Buffer.from("preview")
    throw Object.assign(new Error("missing"), { code: "ENOENT" })
  })
  mocks.rename.mockImplementation(async (_source: string, path: string) => {
    saved.add(path)
  })
  mocks.stat.mockResolvedValue({ size: 16 })
})

it("deduplicates concurrent renders and bounds both active work and queued requests", async () => {
  const { mediaPreview } = await import("./media-previews.js")
  const started = Promise.withResolvers<void>()
  const release = Promise.withResolvers<void>()
  mocks.render.mockImplementation(() => {
    if (mocks.render.mock.calls.length === 2) started.resolve()
    return release.promise
  })
  const pending = Array.from({ length: 66 }, (_, index) =>
    mediaPreview("image", "image/png", "/cache", String(index))
  )
  const duplicate = mediaPreview("image", "image/png", "/cache", "0")
  await started.promise
  await expect(mediaPreview("image", "image/png", "/cache", "overflow")).rejects.toThrow(
    "queue is full"
  )
  expect(mocks.render).toHaveBeenCalledTimes(2)
  release.resolve()
  const results = await Promise.all([...pending, duplicate])
  expect(results.every((result) => result.equals(Buffer.from("preview")))).toBe(true)
  expect(mocks.render).toHaveBeenCalledTimes(66)
})

it("propagates cache and oversized-render errors while releasing render capacity", async () => {
  const { mediaPreview } = await import("./media-previews.js")
  mocks.readFile.mockRejectedValueOnce(Object.assign(new Error("denied"), { code: "EACCES" }))
  await expect(mediaPreview("image", "image/png", "/cache", "denied")).rejects.toThrow("denied")
  mocks.stat.mockResolvedValueOnce({ size: 1024 * 1024 + 1 })
  await expect(mediaPreview("image", "image/png", "/cache", "large")).rejects.toThrow("size limit")
  expect(mocks.rm).toHaveBeenCalledOnce()
  expect(await mediaPreview("image", "image/png", "/cache", "retry")).toEqual(
    Buffer.from("preview")
  )
})

it("handles missing encoders, subprocess errors, and timed-out video decoders", async () => {
  const { mediaPreview } = await import("./media-previews.js")
  mocks.encoder.value = null
  await expect(mediaPreview("video", "video/mp4", "/cache", "missing")).rejects.toThrow(
    "unavailable"
  )
  mocks.encoder.value = "/ffmpeg"
  for (const mode of ["error", "timeout"]) {
    const started = Promise.withResolvers<void>()
    const child = Object.assign(new EventEmitter(), {
      stderr: new EventEmitter(),
      kill: vi.fn(() => {
        child.emit("close", 1)
        return true
      })
    })
    mocks.spawn.mockImplementation(() => {
      started.resolve()
      return child
    })
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    try {
      const result = mediaPreview("video", "video/mp4", "/cache", mode)
      const rejected = expect(result).rejects.toThrow(
        mode === "error" ? "spawn failed" : "decoder detail"
      )
      await started.promise
      if (mode === "error") child.emit("error", new Error("spawn failed"))
      else {
        child.stderr.emit("data", Buffer.from("decoder detail"))
        await vi.advanceTimersByTimeAsync(29999)
        expect(child.kill).not.toHaveBeenCalled()
        await vi.advanceTimersByTimeAsync(1)
        expect(child.kill).toHaveBeenCalledWith("SIGKILL")
      }
      await rejected
    } finally {
      vi.useRealTimers()
    }
  }
})

it("terminates timed-out PDF workers and surfaces worker failures", async () => {
  const { mediaPreview } = await import("./media-previews.js")
  for (const mode of ["error", "exit", "timeout"]) {
    const started = Promise.withResolvers<void>()
    const worker = Object.assign(new EventEmitter(), { terminate: vi.fn() })
    mocks.worker.mockImplementation(() => {
      started.resolve()
      return worker
    })
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    try {
      const result = mediaPreview("pdf", "application/pdf", "/cache", mode)
      const rejected = expect(result).rejects.toThrow(
        mode === "error" ? "worker error" : mode === "exit" ? "exited (1)" : "timed out"
      )
      await started.promise
      if (mode === "error") worker.emit("error", new Error("worker error"))
      if (mode === "exit") worker.emit("exit", 1)
      if (mode === "timeout") {
        await vi.advanceTimersByTimeAsync(29999)
        expect(worker.terminate).not.toHaveBeenCalled()
        await vi.advanceTimersByTimeAsync(1)
        expect(worker.terminate).toHaveBeenCalledOnce()
      }
      await rejected
    } finally {
      vi.useRealTimers()
    }
  }
})
