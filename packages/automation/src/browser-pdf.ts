import { extname } from "node:path"
import { Worker } from "node:worker_threads"

import { evaluate, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { isPlainRecord, isStringArray } from "./unknown-values.js"

export const pdfSnapshotNote =
  "[This tab shows a PDF, so the outline above is only the viewer. Read the document's text with tab.content.export({ format: 'markdown' }).]"

export const showsPdf = async (runtime: BrowserRuntime, page: PageHandle): Promise<boolean> =>
  (await evaluate(runtime, page, "document.contentType === 'application/pdf'")) === true

export const pdfMarkdown = async (runtime: BrowserRuntime, page: PageHandle): Promise<string> => {
  const fetched = await evaluate(runtime, page, pdfDocumentExpression)
  if (!isPlainRecord(fetched) || typeof fetched.url !== "string")
    throw new Error("The PDF could not be read from the tab")
  if (typeof fetched.base64 !== "string") throw new Error(unreadablePdf(fetched))

  const pages = await pdfPageTexts(Buffer.from(fetched.base64, "base64"))
  return [`# ${String(fetched.title)}`, `Source: ${fetched.url}`, ...pages.map(pageSection)].join(
    "\n\n"
  )
}

export const pdfPageTexts = (document: Uint8Array): Promise<string[]> =>
  new Promise((resolve, reject) => {
    const worker = new Worker(pdfTextWorkerUrl(), {
      workerData: document,
      resourceLimits: { maxOldGenerationSizeMb: pdfTextMemoryMb }
    })
    const timer = setTimeout(() => {
      void worker.terminate()
      reject(new Error("Reading the PDF's text took too long"))
    }, pdfTextTimeoutMs)
    timer.unref()
    const settle = (finish: () => void) => {
      clearTimeout(timer)
      finish()
    }
    worker.once("message", (pages: unknown) => {
      settle(() => {
        if (isStringArray(pages)) resolve(pages)
        else reject(new Error("The PDF text reader returned no pages"))
      })
    })
    worker.once("error", (cause) => {
      settle(() => {
        reject(
          new Error(
            `The PDF could not be read: ${cause instanceof Error ? cause.message : String(cause)}`
          )
        )
      })
    })
    worker.once("exit", (code) => {
      settle(() => {
        reject(new Error(`The PDF text reader stopped early (${code})`))
      })
    })
  })

const maxPdfBytes = 50 * 1024 * 1024
const pdfTextTimeoutMs = 30_000
const pdfTextMemoryMb = 256

const pdfDocumentExpression = `(async () => {
  const about = { url: location.href, title: document.title || location.pathname.split('/').pop() || 'PDF' }
  const response = await fetch(location.href, { credentials: 'include' }).catch(() => undefined)
  if (response === undefined || !response.ok) return { ...about, status: response ? response.status : 0 }
  const blob = await response.blob()
  if (blob.size > ${maxPdfBytes}) return { ...about, size: blob.size }
  const dataUrl = await new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(reader.result)
    reader.onerror = () => reject(reader.error)
    reader.readAsDataURL(blob)
  })
  return { ...about, base64: String(dataUrl).slice(String(dataUrl).indexOf(',') + 1) }
})()`

const unreadablePdf = (fetched: Readonly<Record<string, unknown>>): string => {
  if (typeof fetched.size === "number")
    return `The PDF is ${Math.round(fetched.size / 1024 / 1024)} MB; its text can be read up to ${maxPdfBytes / 1024 / 1024} MB`
  return `The PDF could not be fetched again to read its text (status ${String(fetched.status)})`
}

const pageSection = (text: string, index: number): string =>
  `## Page ${index + 1}\n\n${text.trim() === "" ? "(no text on this page; it may be a scan)" : text.trim()}`

const pdfTextWorkerUrl = (): URL =>
  new URL(`./browser-pdf-text-worker${extname(new URL(import.meta.url).pathname)}`, import.meta.url)
