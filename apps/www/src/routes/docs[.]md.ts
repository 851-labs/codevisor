import { createFileRoute } from "@tanstack/react-router"

import { getPageMarkdown, markdownResponse } from "../lib/llm-text"

export const Route = createFileRoute("/docs.md")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const pageUrl = new URL("/docs", request.url)
        return markdownResponse(await getPageMarkdown([], pageUrl.toString()))
      }
    }
  }
})
