import { createFileRoute } from "@tanstack/react-router"
import { latestMacOSDownloadURL } from "../lib/github-release"

// GitHub Releases is the stable-release source of truth. `?arch=arm64|x64`
// selects the matching DMG (arm64 by default). The direct latest-download URL
// avoids consuming GitHub's anonymous API quota on each website request.
export const Route = createFileRoute("/download/macos")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const requestedArch = new URL(request.url).searchParams.get("arch")
        const arch = requestedArch === "x64" ? "x64" : "arm64"
        return new Response(null, {
          status: 302,
          headers: {
            Location: latestMacOSDownloadURL(arch),
            "Cache-Control": "public, max-age=300"
          }
        })
      }
    }
  }
})
