import { createFileRoute } from "@tanstack/react-router"

import { latestMacOSDownloadURL } from "../lib/github-release"

// GitHub Releases is the stable-release source of truth. The app ships for
// Apple silicon only, so every request gets the arm64 DMG. The direct
// latest-download URL avoids consuming GitHub's anonymous API quota on each
// website request.
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
