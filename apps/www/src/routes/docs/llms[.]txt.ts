import { createFileRoute } from "@tanstack/react-router"

import { getLlmsIndex } from "../../lib/llm-text"

export const Route = createFileRoute("/docs/llms.txt")({
  server: {
    handlers: {
      GET: async ({ request }) =>
        new Response(await getLlmsIndex(request.url), {
          headers: {
            "Cache-Control": "public, max-age=0, s-maxage=3600",
            "Content-Type": "text/plain; charset=utf-8"
          }
        })
    }
  }
})
