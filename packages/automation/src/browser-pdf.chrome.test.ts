import { readFileSync } from "node:fs"
import { createServer } from "node:http"

import { describe, expect, onTestFinished } from "vitest"

import { chromeBrowserSuite } from "./browser-chrome-test-support.js"
import { pdfWithPages } from "./browser-pdf-test-support.js"

const it = chromeBrowserSuite("pdf", () => ({}))

const pdfSite = async (texts: ReadonlyArray<string>): Promise<string> => {
  const server = createServer((_request, response) => {
    response.setHeader("content-type", "application/pdf")
    response.end(pdfWithPages(texts))
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(async () => {
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("No TCP address")
  return `http://127.0.0.1:${address.port}`
}

describe("PDF tabs", () => {
  it("points the snapshot at the markdown export, which holds every page's text", async ({
    browser
  }) => {
    const site = await pdfSite(["Invoice total 42 dollars", "Thank you"])
    await browser.cell(`await tab.goto(${JSON.stringify(`${site}/invoice.pdf`)})`)
    const note = await browser.cell("(await tab.getAXState()).split('\\n').at(-1)")
    const path = String(
      await browser.cell("(await tab.content.export({format:'markdown'})).file.path")
    )
    expect(note).toBe(
      "[This tab shows a PDF, so the outline above is only the viewer. Read the document's text with tab.content.export({ format: 'markdown' }).]"
    )
    expect(readFileSync(path, "utf8")).toBe(
      `# invoice.pdf\n\nSource: ${site}/invoice.pdf\n\n## Page 1\n\nInvoice total 42 dollars\n\n## Page 2\n\nThank you`
    )
  })
})
