import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { parentPort, workerData } from "node:worker_threads"

import { getDocument, VerbosityLevel } from "pdfjs-dist/legacy/build/pdf.mjs"

const input: unknown = workerData
const port = parentPort
if (!(input instanceof Uint8Array) || port === null)
  throw new Error("The PDF text worker needs the document bytes and a parent to answer")

const packageRoot = dirname(fileURLToPath(import.meta.resolve("pdfjs-dist/package.json")))
const task = getDocument({
  data: input,
  disableAutoFetch: true,
  disableStream: true,
  useSystemFonts: false,
  standardFontDataUrl: `${join(packageRoot, "standard_fonts")}/`,
  verbosity: VerbosityLevel.ERRORS
})
try {
  const pdf = await task.promise
  const pages: string[] = []
  for (let number = 1; number <= pdf.numPages; number++) {
    const page = await pdf.getPage(number)
    const content = await page.getTextContent()
    const text = content.items
      .map((item) => ("str" in item ? item.str + (item.hasEOL ? "\n" : "") : ""))
      .join("")
    pages.push(text)
  }
  port.postMessage(pages)
} finally {
  await task.destroy()
}
