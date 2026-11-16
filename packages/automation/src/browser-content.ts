import { randomUUID } from "node:crypto"
import { writeFile } from "node:fs/promises"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/server"

import { evaluate, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { frameMarkdownSections } from "./browser-frame-text.js"
import { expectString } from "./unknown-values.js"

const contentTypes = {
  markdown: ["md", "text/markdown"],
  html: ["html", "text/html"],
  pdf: ["pdf", "application/pdf"]
} as const

const pageMarkdownExpression =
  "'# ' + document.title + '\\n\\nSource: ' + location.href + '\\n\\n' + document.body.innerText"

const pageMarkdown = async (runtime: BrowserRuntime, page: PageHandle): Promise<string> => {
  const own = expectString(await evaluate(runtime, page, pageMarkdownExpression), "Page export")
  const frames = await frameMarkdownSections(runtime, page).catch(() => "")
  return own + frames
}

const isContentFormat = (format: string): format is keyof typeof contentTypes =>
  Object.hasOwn(contentTypes, format)

export const exportBrowserContent = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  directory: string,
  format = "markdown"
): Promise<CallToolResult> => {
  if (!isContentFormat(format))
    throw new Error("Content export format must be markdown, html, or pdf")
  const [extension, mimeType] = contentTypes[format]
  let bytes: Buffer
  if (format === "pdf") {
    bytes = Buffer.from(
      (
        await runtime.connection.send<{ data: string }>(
          "Page.printToPDF",
          { printBackground: true },
          page.sessionId
        )
      ).data,
      "base64"
    )
  } else if (format === "html") {
    bytes = Buffer.from(
      expectString(
        await evaluate(runtime, page, "document.documentElement.outerHTML"),
        "Page export"
      )
    )
  } else {
    bytes = Buffer.from(await pageMarkdown(runtime, page))
  }
  if (bytes.length > 20 * 1024 * 1024)
    throw new Error("Page export exceeds the 20 MB attachment limit")
  const name = `page-${randomUUID()}.${extension}`
  const path = join(directory, name)
  await writeFile(path, bytes, { mode: 0o600 })
  return {
    content: [
      {
        type: "text",
        text: JSON.stringify({ file: { path, name, mimeType, sizeBytes: bytes.length } })
      },
      {
        type: "resource",
        resource: { uri: `browser-export:${name}`, mimeType, blob: bytes.toString("base64") }
      }
    ]
  }
}
