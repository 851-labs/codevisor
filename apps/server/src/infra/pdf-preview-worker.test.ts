import { expect, it, vi } from "vitest"
const mocks = vi.hoisted(() => ({ document: vi.fn(), canvas: vi.fn(), write: vi.fn() }))
vi.mock("node:worker_threads", () => ({
  workerData: { path: "/document.pdf", output: "/preview.png" }
}))
vi.mock("node:fs/promises", () => ({ writeFile: mocks.write }))
vi.mock("@napi-rs/canvas", () => ({ createCanvas: mocks.canvas }))
vi.mock("pdfjs-dist/legacy/build/pdf.mjs", () => ({ getDocument: mocks.document }))

it("renders only the first PDF page within preview bounds and always destroys the document", async () => {
  const render = vi.fn(() => ({ promise: Promise.resolve() }))
  const viewport = vi.fn(({ scale }: { scale: number }) => ({
    width: 1200 * scale,
    height: 600 * scale
  }))
  const getPage = vi.fn(async () => ({ getViewport: viewport, render }))
  const destroy = vi.fn()
  mocks.document.mockReturnValue({ promise: Promise.resolve({ getPage }), destroy })
  mocks.canvas.mockReturnValue({ encode: vi.fn(async () => Buffer.from("png")) })
  await import("./pdf-preview-worker.js")
  expect(getPage).toHaveBeenCalledWith(1)
  expect(mocks.canvas).toHaveBeenCalledWith(480, 240)
  expect(mocks.write).toHaveBeenCalledWith("/preview.png", Buffer.from("png"))
  expect(destroy).toHaveBeenCalledOnce()
  vi.resetModules()
  mocks.document.mockReturnValue({ promise: Promise.reject(new Error("broken document")), destroy })
  await expect(import("./pdf-preview-worker.js")).rejects.toThrow("broken document")
  expect(destroy).toHaveBeenCalledTimes(2)
})
