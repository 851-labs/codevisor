import { randomUUID } from "node:crypto"
import { writeFile } from "node:fs/promises"
import { join } from "node:path"
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js"
import { evaluate, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"

/** Export only the selected page. Binary content follows the existing attachment pipeline. */
export const exportBrowserContent = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  directory: string,
  format = "markdown"
): Promise<CallToolResult> => {
  const types = {
    markdown: ["md", "text/markdown"],
    html: ["html", "text/html"],
    pdf: ["pdf", "application/pdf"]
  } as const
  if (!(format in types)) throw new Error("Content export format must be markdown, html, or pdf")
  const [extension, mimeType] = types[format as keyof typeof types]
  const bytes =
    format === "pdf"
      ? Buffer.from(
          (
            await runtime.connection.send<{ data: string }>(
              "Page.printToPDF",
              { printBackground: true },
              page.sessionId
            )
          ).data,
          "base64"
        )
      : Buffer.from(
          await evaluate<string>(
            runtime,
            page,
            format === "html"
              ? "document.documentElement.outerHTML"
              : "'# ' + document.title + '\\n\\nSource: ' + location.href + '\\n\\n' + document.body.innerText"
          )
        )
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
