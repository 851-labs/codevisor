const pageContent = (text: string): string => {
  const drawing = `BT /F1 24 Tf 72 700 Td (${text}) Tj ET`
  return `<< /Length ${drawing.length} >>\nstream\n${drawing}\nendstream`
}

const pageObject = (contentsId: number, fontId: number): string =>
  `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents ${contentsId} 0 R /Resources << /Font << /F1 ${fontId} 0 R >> >> >>`

export const pdfWithPages = (texts: ReadonlyArray<string>): Uint8Array => {
  const fontId = 3 + texts.length * 2
  const kids = texts.map((_, index) => `${3 + index * 2} 0 R`).join(" ")
  const bodies = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    `<< /Type /Pages /Kids [${kids}] /Count ${texts.length} >>`,
    ...texts.flatMap((text, index) => [pageObject(4 + index * 2, fontId), pageContent(text)]),
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
  ]
  let document = "%PDF-1.4\n"
  const offsets = bodies.map((body, index) => {
    const offset = document.length
    document += `${index + 1} 0 obj\n${body}\nendobj\n`
    return offset
  })
  const crossReference = document.length
  const entries = offsets.map((offset) => `${String(offset).padStart(10, "0")} 00000 n \n`).join("")
  document += `xref\n0 ${bodies.length + 1}\n0000000000 65535 f \n${entries}`
  document += `trailer\n<< /Size ${bodies.length + 1} /Root 1 0 R >>\nstartxref\n${crossReference}\n%%EOF\n`
  return new TextEncoder().encode(document)
}
