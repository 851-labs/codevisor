import { describe, expect, it } from "vitest"

import { pdfWithPages } from "./browser-pdf-test-support.js"
import { pdfPageTexts } from "./browser-pdf.js"

describe("PDF text", () => {
  it("reads each page's text in order", async () => {
    const pages = await pdfPageTexts(pdfWithPages(["Invoice total 42 dollars", "Thank you"]))
    expect(pages).toEqual(["Invoice total 42 dollars", "Thank you"])
  })

  it("says the file could not be read when it isn't a PDF", async () => {
    await expect(pdfPageTexts(new TextEncoder().encode("<html>not a pdf</html>"))).rejects.toThrow(
      /^The PDF could not be read: /
    )
  })
})
