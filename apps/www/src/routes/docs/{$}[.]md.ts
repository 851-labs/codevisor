import { createFileRoute } from "@tanstack/react-router"

import { getPageMarkdown, markdownResponse } from "../../lib/llm-text"

export const Route = createFileRoute("/docs/{$}.md")({
  server: {
    handlers: {
      GET: async ({ params, request }) => {
        const slugs = params._splat?.split("/").filter(Boolean) ?? []
        const pageUrl = new URL(request.url)
        pageUrl.pathname = pageUrl.pathname.slice(0, -".md".length)

        return markdownResponse(await getPageMarkdown(slugs, pageUrl.toString()))
      }
    }
  }
})
