import { createFileRoute } from "@tanstack/react-router"

const RELEASE_BASE = "https://pub-d2d6eb72b71c4986a742c0527774c9f0.r2.dev/releases/codevisor"

// Resolves the latest release from the public R2 manifest and redirects to the
// DMG. Releases published before the DMG existed only have the zip, so fall
// back to it when the DMG isn't there.
export const Route = createFileRoute("/download/macos")({
  server: {
    handlers: {
      GET: async () => {
        const manifest = await fetch(`${RELEASE_BASE}/latest.json`)
        if (!manifest.ok) {
          return new Response("Release manifest unavailable", { status: 502 })
        }
        const { version } = (await manifest.json()) as { version: string }
        const v = version.replace(/^v/, "")
        const dmgUrl = `${RELEASE_BASE}/v${v}/Codevisor.dmg`
        const dmg = await fetch(dmgUrl, { method: "HEAD" })
        const target = dmg.ok ? dmgUrl : `${RELEASE_BASE}/v${v}/Codevisor-macOS.zip`
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
