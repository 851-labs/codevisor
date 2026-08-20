import { createFileRoute } from "@tanstack/react-router"

export const Route = createFileRoute("/llms.txt")({
  server: {
    handlers: {
      GET: ({ request }) =>
        new Response(null, {
          status: 301,
          headers: { Location: new URL("/docs/llms.txt", request.url).toString() }
        })
    }
  }
})
