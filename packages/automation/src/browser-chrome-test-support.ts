import { mkdtempSync, rmSync } from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CallToolResult } from "@modelcontextprotocol/server"
import { afterAll, beforeAll, it as baseIt, vi } from "vitest"

import { emulateBrowserFocus } from "./browser-cdp-test-support.js"
import { makeBrowserUseProvider } from "./browser-use-provider.js"

export interface ChromeFixtureOrigins {
  readonly origin: string
  readonly crossOrigin: string
}

export interface ChromeBrowser {
  readonly context: { readonly sessionId: string; readonly projectId: string }
  readonly origins: ChromeFixtureOrigins
  readonly cell: (code: string) => Promise<unknown>
  readonly open: (path: string) => Promise<void>
  readonly endTurn: () => Promise<void>
}

export type ChromeFixturePages = (origins: ChromeFixtureOrigins) => Readonly<Record<string, string>>

export const toolValue = (result: CallToolResult): unknown => {
  const message = result.content
    .filter((content) => content.type === "text")
    .map((content) => content.text)
    .join("\n")
  if (result.isError) throw new Error(message)
  try {
    return JSON.parse(message)
  } catch {
    return message
  }
}

export const chromeBrowserSuite = (projectId: string, pages: ChromeFixturePages) => {
  let provider: ReturnType<typeof makeBrowserUseProvider>
  let origins: ChromeFixtureOrigins
  let directory: string
  const server = createServer((request, response) => {
    const html = pages(origins)[request.url ?? "/"]
    if (html === undefined) {
      response.statusCode = 404
      response.end()
      return
    }
    response.setHeader("content-type", "text/html")
    response.end(`<!doctype html>${html}`)
  })

  beforeAll(async () => {
    emulateBrowserFocus()
    directory = mkdtempSync(join(tmpdir(), `browser-${projectId}-`))
    provider = makeBrowserUseProvider(directory, "http://127.0.0.1:43210")
    origins = await listen(server)
    const warmup = { sessionId: "warmup", projectId }
    toolValue(await provider.invoke(warmup, "use_backend", { backend: "managed" }))
    toolValue(await provider.invoke(warmup, "tabs", { action: "list" }))
  })

  afterAll(async () => {
    try {
      await provider?.close()
    } finally {
      server.closeAllConnections()
      await new Promise<void>((resolve) => server.close(() => resolve()))
      rmSync(directory, { recursive: true, force: true })
      vi.restoreAllMocks()
    }
  })

  return baseIt.extend<{ browser: ChromeBrowser }>({
    browser: async ({ task }, use) => {
      const context = { sessionId: task.id, projectId }
      const cell = async (code: string) => toolValue(await provider.invoke(context, "js", { code }))
      const open = async (path: string) => {
        await cell(
          `await tab.playwright.expectNavigation(() => tab.goto(${JSON.stringify(origins.origin + path)}), {waitUntil: 'load'})`
        )
      }
      try {
        toolValue(await provider.invoke(context, "use_backend", { backend: "managed" }))
        await cell("var tab = await browser.tabs.new()")
        const endTurn = async () => {
          await provider.finishTurn?.(context.sessionId)
        }
        await use({ context, origins, cell, open, endTurn })
      } finally {
        await provider.closeSession(context.sessionId)
      }
    }
  })
}

const listen = (server: ReturnType<typeof createServer>): Promise<ChromeFixtureOrigins> =>
  new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, "127.0.0.1", () => {
      const address = server.address()
      if (!address || typeof address === "string") {
        reject(new Error("Missing fixture address"))
        return
      }
      resolve({
        origin: `http://127.0.0.1:${address.port}`,
        crossOrigin: `http://localhost:${address.port}`
      })
    })
  })
