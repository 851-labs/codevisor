import { createFileRoute } from "@tanstack/react-router"

const RELEASE_BASE = "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"

// Resolves the latest release from the public R2 manifest and redirects to
// the best matching DMG. `?arch=arm64|x64` selects the architecture-specific
// image published by split releases (defaults to arm64, the overwhelming
// majority of Macs); releases from before the split fall back to the
// universal DMG, and releases from before the DMG existed fall back to the
// zip.
export const Route = createFileRoute("/download/macos")({
  server: {
    handlers: {
      GET: async ({ request }) => {
        const manifest = await fetch(`${RELEASE_BASE}/latest.json`)
        if (!manifest.ok) {
          return new Response("Release manifest unavailable", { status: 502 })
        }
        const { version } = (await manifest.json()) as { version: string }
        const v = version.replace(/^v/, "")
        const requestedArch = new URL(request.url).searchParams.get("arch")
        const arch = requestedArch === "x64" ? "x64" : "arm64"
        const candidates = [
          `${RELEASE_BASE}/v${v}/Codevisor-${arch}.dmg`,
          `${RELEASE_BASE}/v${v}/Codevisor.dmg`
        ]
        let target = `${RELEASE_BASE}/v${v}/Codevisor-macOS.zip`
        for (const candidate of candidates) {
          const probe = await fetch(candidate, { method: "HEAD" })
          if (probe.ok) {
            target = candidate
            break
          }
        }
        return new Response(null, {
          status: 302,
          headers: {
            Location: target,
            "Cache-Control": "public, max-age=60"
          }
        })
      }
    }
  }
})
