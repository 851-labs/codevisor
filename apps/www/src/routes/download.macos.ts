import { createFileRoute } from "@tanstack/react-router"

import { latestMacOSDownloadURL } from "../lib/github-release"

export const Route = createFileRoute("/download/macos")({
  server: {
    handlers: {
      GET: async () =>
        new Response(null, {
          status: 302,
          headers: {
            Location: latestMacOSDownloadURL(),
            "Cache-Control": "public, max-age=300"
          }
        })
    }
  }
})
