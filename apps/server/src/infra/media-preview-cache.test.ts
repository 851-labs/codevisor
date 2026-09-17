import { beforeEach, expect, it, vi } from "vitest"
const mocks = vi.hoisted(() => ({ opendir: vi.fn(), stat: vi.fn(), rm: vi.fn() }))
vi.mock("node:fs/promises", () => mocks)
beforeEach(() => {
  vi.resetModules()
  vi.resetAllMocks()
})

it("evicts only old derived previews, skipping unrelated files and vanished entries", async () => {
  const { trimMediaPreviewCache } = await import("./media-preview-cache.js")
  const names = [
    "original.jpg",
    "f".repeat(64) + ".png",
    ...Array.from({ length: 4096 }, (_, index) => index.toString(16).padStart(64, "0") + ".png")
  ]
  mocks.opendir.mockResolvedValue(
    (async function* () {
      for (const name of names) yield { name }
    })()
  )
  mocks.stat.mockImplementation(async (path: string) => {
    if (path.endsWith("f".repeat(64) + ".png")) throw new Error("gone")
    return { size: 16, mtimeMs: Number.parseInt(path.split("/").at(-1)!, 16) }
  })
  await trimMediaPreviewCache("/previews")
  expect(mocks.rm).toHaveBeenCalledTimes(2048)
  expect(mocks.rm).toHaveBeenNthCalledWith(1, `/previews/${"0".repeat(64)}.png`, { force: true })
  expect(mocks.stat).not.toHaveBeenCalledWith("/previews/original.jpg")
})

it("shares scans and bounds cache bytes independently of file count", async () => {
  const { trimMediaPreviewCache } = await import("./media-preview-cache.js")
  const release = Promise.withResolvers<void>()
  const started = Promise.withResolvers<void>()
  mocks.opendir.mockImplementation(async () => {
    started.resolve()
    await release.promise
    return (async function* () {
      for (let index = 0; index < 4; index++)
        yield { name: index.toString(16).padStart(64, "0") + ".png" }
    })()
  })
  mocks.stat.mockResolvedValue({ size: 100 * 1024 * 1024, mtimeMs: 1 })
  const pending = trimMediaPreviewCache("/previews")
  await started.promise
  const repeats = Array.from({ length: 64 }, () => trimMediaPreviewCache("/previews"))
  expect(mocks.opendir).toHaveBeenCalledOnce()
  release.resolve()
  await Promise.all([pending, ...repeats])
  expect(mocks.rm).toHaveBeenCalledTimes(2)
})
