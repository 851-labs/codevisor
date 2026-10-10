import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import sharp from "sharp"
import { afterEach, describe, expect, it } from "vitest"

import {
  allowedMcpIconUrl,
  isInertSvg,
  makeToolIconStore,
  normalizeIcon,
  pageIconCandidates,
  registrableDomain,
  sniffImageFormat,
  TOOL_ICON_MAX_BYTES,
  type McpIconSources,
  type ToolIconStoreOptions
} from "./tool-icons.js"

const directories: Array<string> = []
afterEach(async () => {
  await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

const png = (side: number): Promise<Buffer> =>
  sharp({
    create: { width: side, height: side, channels: 4, background: { r: 200, g: 0, b: 0, alpha: 1 } }
  })
    .png()
    .toBuffer()

const ICO = Buffer.from([0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x10, 0x10])
const SVG =
  '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>'

/// Each request gets a fresh response: a cloned body's cancel waits on its twin.
type Route = (() => Response) | Error

/// A fetch over fixed routes that records what was asked for. Unrouted
/// URLs answer 404.
const fakeFetch = (routes: Record<string, Route>) => {
  const requested: Array<{ url: string; init: RequestInit | undefined }> = []
  const fetchImpl = (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input)
    requested.push({ url, init })
    const route = routes[url]
    if (route instanceof Error) throw route
    if (route === undefined) return new Response(null, { status: 404 })
    return route()
  }) as typeof fetch
  return { fetchImpl, requested: () => requested.map((entry) => entry.url), calls: requested }
}

const html = (head: string) => (): Response =>
  new Response(`<html><head>${head}</head><body>page</body></html>`, {
    headers: { "content-type": "text/html" }
  })

const image = (data: Uint8Array) => (): Response => new Response(Buffer.from(data))

/// A response that claims to come from `url`, as a followed redirect does.
const redirected = (route: () => Response, url: string) => (): Response => {
  const response = route()
  Object.defineProperty(response, "url", { value: url })
  return response
}

const streamOf = (chunk: Uint8Array, count: number): Response =>
  new Response(
    new ReadableStream({
      start(controller) {
        for (let index = 0; index < count; index += 1) controller.enqueue(chunk)
        controller.close()
      }
    })
  )

const store = async (
  routes: Record<string, Route>,
  overrides: Partial<ToolIconStoreOptions> = {}
) => {
  const dir = await mkdtemp(join(tmpdir(), "tool-icons-"))
  directories.push(dir)
  const fetched = fakeFetch(routes)
  let now = 1_000_000
  const refreshes: Array<Promise<unknown>> = []
  const icons = makeToolIconStore({
    dir,
    fetchImpl: fetched.fetchImpl,
    now: () => now,
    background: (refresh) => {
      refreshes.push(refresh)
    },
    ...overrides
  })
  return {
    dir,
    icons,
    ...fetched,
    advance: (ms: number) => {
      now += ms
    },
    refreshes
  }
}

const DAY = 24 * 60 * 60 * 1000

describe("page icon candidates", () => {
  it("prefers sized icons near 64px, then SVGs, small rasters, unsized icons, and touch icons", () => {
    const page = `
      <link rel="apple-touch-icon" href="/touch.png">
      <link rel="icon" href="/plain.ico">
      <link rel="icon" sizes="16x16" href="/16.png">
      <link rel="icon" type="image/svg+xml" href="/logo.svg">
      <link rel="shortcut icon" sizes="32x32 192x192" href="/192.png">
      <link rel=icon sizes=96x96 href=/96.png?a=1&amp;b=2>
      <link rel="mask-icon" href="/mask.svg">
      <link rel="icon" href="javascript:alert(1)">
      <link rel="icon" href="http://[bad">
      <link rel="icon">
      <link rel="stylesheet" href="/style.css">
      <link href="/no-rel.png">
      <link rel="icon" sizes="large" href="/unsized-too.png">
      <link rel="icon" href="/96.png?a=1&b=2">`
    expect(pageIconCandidates(page, "https://example.com/start")).toEqual([
      "https://example.com/96.png?a=1&b=2",
      "https://example.com/logo.svg",
      "https://example.com/192.png",
      "https://example.com/16.png",
      "https://example.com/plain.ico",
      "https://example.com/unsized-too.png",
      "https://example.com/touch.png"
    ])
  })

  it("chooses the variant a page declares for the appearance", () => {
    const page = `
      <link rel="icon" href="/light.png" sizes="64x64" media="(prefers-color-scheme: light)">
      <link rel="icon" href="/dark.png" sizes="64x64" media="(prefers-color-scheme: dark)">
      <link rel="icon" href="data:image/png;base64,AAAA" sizes="any">`
    expect(pageIconCandidates(page, "https://example.com/", "light")[0]).toBe(
      "https://example.com/light.png"
    )
    expect(pageIconCandidates(page, "https://example.com/", "dark")).toEqual([
      "https://example.com/dark.png",
      "data:image/png;base64,AAAA",
      "https://example.com/light.png"
    ])
  })
})

describe("icon images", () => {
  it("recognizes formats by their bytes", async () => {
    expect(sniffImageFormat(await png(4))).toBe("png")
    expect(sniffImageFormat(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe("jpeg")
    expect(sniffImageFormat(Buffer.from("GIF89a"))).toBe("gif")
    expect(sniffImageFormat(Buffer.from("RIFF\0\0\0\0WEBPVP8 "))).toBe("webp")
    expect(sniffImageFormat(ICO)).toBe("ico")
    expect(sniffImageFormat(Buffer.from(`<?xml version="1.0"?>\n<!-- logo -->\n${SVG}`))).toBe(
      "svg"
    )
    expect(sniffImageFormat(Buffer.from("<html></html>"))).toBeUndefined()
  })

  it("keeps SVGs that stay inside themselves", () => {
    expect(isInertSvg(SVG)).toBe(true)
    expect(isInertSvg('<svg><use href="#a"/><rect fill="url(#g)"/></svg>')).toBe(true)
    expect(isInertSvg("<svg><script>alert(1)</script></svg>")).toBe(false)
    expect(isInertSvg('<!DOCTYPE svg [<!ENTITY x "y">]><svg/>')).toBe(false)
    expect(isInertSvg('<svg><image href="https://tracker.example/p.png"/></svg>')).toBe(false)
    expect(isInertSvg('<svg><rect fill="url(https://x.example/a)"/></svg>')).toBe(false)
  })

  it("normalizes rasters and SVGs to bounded PNGs, passes ICO through, and refuses the rest", async () => {
    const large = await normalizeIcon(await png(512))
    expect(large?.contentType).toBe("image/png")
    expect((await sharp(large!.data).metadata()).width).toBe(128)
    const small = await normalizeIcon(await png(16))
    expect((await sharp(small!.data).metadata()).width).toBe(16)
    expect(await normalizeIcon(Buffer.from(SVG))).toMatchObject({ contentType: "image/png" })
    expect(await normalizeIcon(ICO)).toEqual({ contentType: "image/x-icon", data: ICO })
    expect(await normalizeIcon(Buffer.from("<svg><script/></svg>"))).toBeUndefined()
    expect(await normalizeIcon(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0, 0]))).toBeUndefined()
    expect(await normalizeIcon(Buffer.from("plain text"))).toBeUndefined()
  })
})

describe("MCP icon origins", () => {
  it("reduces hosts to their registrable domain", () => {
    expect(registrableDomain("mcp.linear.app")).toBe("linear.app")
    expect(registrableDomain("linear.app")).toBe("linear.app")
    expect(registrableDomain("mcp.example.co.uk")).toBe("example.co.uk")
    expect(registrableDomain("a.b.example.io")).toBe("example.io")
    expect(registrableDomain("10.0.0.12")).toBe("10.0.0.12")
  })

  it("accepts only HTTPS icons from the server's own domain, and data URIs", () => {
    const server = "https://mcp.linear.app/mcp"
    expect(allowedMcpIconUrl("https://linear.app/icon.png", server)).toBe(true)
    expect(allowedMcpIconUrl("https://cdn.linear.app/icon.png", server)).toBe(true)
    expect(allowedMcpIconUrl("data:image/png;base64,AAAA", undefined)).toBe(true)
    expect(allowedMcpIconUrl("https://tracker.example/icon.png", server)).toBe(false)
    expect(allowedMcpIconUrl("http://linear.app/icon.png", server)).toBe(false)
    expect(allowedMcpIconUrl("https://linear.app/icon.png", undefined)).toBe(false)
    expect(allowedMcpIconUrl("https://linear.app/icon.png", "not a url")).toBe(false)
    expect(allowedMcpIconUrl("not a url", server)).toBe(false)
  })
})

describe("site icons", () => {
  it("fetches a page's best declared icon without credentials, falling through broken ones", async () => {
    const icon = await png(64)
    const { icons, calls, requested } = await store({
      "https://linear.app/": redirected(
        html('<link rel="icon" sizes="64x64" href="/broken.png"><link rel="icon" href="/ok.png">'),
        "https://linear.app/home"
      ),
      "https://linear.app/broken.png": () => new Response("not an image"),
      "https://linear.app/ok.png": image(icon)
    })
    const asset = await icons.site("https://linear.app/some/page", "light")
    expect(asset?.contentType).toBe("image/png")
    expect(requested()).toEqual([
      "https://linear.app/",
      "https://linear.app/broken.png",
      "https://linear.app/ok.png"
    ])
    expect(calls[0]?.init).toMatchObject({ credentials: "omit", redirect: "follow" })
  })

  it("falls back to /favicon.ico on the origin a page redirected to", async () => {
    const { icons, requested } = await store({
      "https://posthog.com/": redirected(html(""), "https://www.posthog.com/"),
      "https://www.posthog.com/favicon.ico": image(ICO)
    })
    expect(await icons.site("https://posthog.com", "dark")).toEqual({
      contentType: "image/x-icon",
      data: new Uint8Array(ICO)
    })
    expect(requested()).toEqual(["https://posthog.com/", "https://www.posthog.com/favicon.ico"])
  })

  it("survives unreachable pages, empty bodies, non-web redirects, and oversized images", async () => {
    const { icons } = await store({
      "https://down.example/": new Error("offline"),
      "https://down.example/favicon.ico": () => new Response(null),
      "https://odd.example/": redirected(html(""), "ftp://odd.example/"),
      "https://odd.example/favicon.ico": () =>
        streamOf(new Uint8Array(64 * 1024), TOOL_ICON_MAX_BYTES / (64 * 1024) + 1)
    })
    expect(await icons.site("https://down.example", "light")).toBeUndefined()
    expect(await icons.site("https://odd.example", "light")).toBeUndefined()
    expect(await icons.site("not a url", "light")).toBeUndefined()
    expect(await icons.site("ftp://files.example", "light")).toBeUndefined()
  })

  it("reads a long head only as far as it must", async () => {
    // Over the page budget with no closing head: the start still counts.
    const filler = new TextEncoder().encode(`<style>${"x".repeat(1024 * 1024)}</style>`)
    const head = new TextEncoder().encode('<link rel="icon" href="/late.png">')
    const { icons, requested } = await store({
      "https://heavy.example/": () =>
        new Response(
          new ReadableStream({
            start(controller) {
              controller.enqueue(head)
              for (let index = 0; index < 3; index += 1) controller.enqueue(filler)
              controller.close()
            }
          })
        ),
      "https://heavy.example/late.png": image(await png(32))
    })
    expect((await icons.site("https://heavy.example", "light"))?.contentType).toBe("image/png")
    expect(requested()).toEqual(["https://heavy.example/", "https://heavy.example/late.png"])
  })

  it("serves cached icons from disk, refreshing stale ones behind the response", async () => {
    const first = await png(32)
    let served = first
    const harness = await store({
      "https://linear.app/": html('<link rel="icon" href="/icon.png">'),
      "https://linear.app/icon.png": () => image(served)()
    })
    const original = await harness.icons.site("https://linear.app", "light")
    expect(harness.requested()).toHaveLength(2)

    // A new store over the same directory reads the disk cache.
    const reopened = makeToolIconStore({
      dir: harness.dir,
      fetchImpl: harness.fetchImpl,
      now: () => 1_000_000 + DAY
    })
    expect(await reopened.site("https://linear.app", "light")).toEqual(original)
    expect(harness.requested()).toHaveLength(2)

    // A week on, the stale icon is still served at once while it refreshes.
    served = await png(48)
    harness.advance(8 * DAY)
    expect(await harness.icons.site("https://linear.app", "light")).toEqual(original)
    expect(harness.refreshes).toHaveLength(1)
    await harness.refreshes[0]
    const refreshed = await harness.icons.site("https://linear.app", "light")
    expect((await sharp(refreshed!.data).metadata()).width).toBe(48)
  })

  it("remembers a missing icon for a while, then looks again", async () => {
    const harness = await store({})
    expect(await harness.icons.site("https://bare.example", "light")).toBeUndefined()
    const asked = harness.requested().length
    expect(await harness.icons.site("https://bare.example", "light")).toBeUndefined()
    expect(harness.requested()).toHaveLength(asked)
    harness.advance(7 * 60 * 60 * 1000)
    expect(await harness.icons.site("https://bare.example", "light")).toBeUndefined()
    expect(harness.requested()).toHaveLength(asked * 2)
  })

  it("still answers when the cache directory can't be written", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tool-icons-blocked-"))
    directories.push(dir)
    const blocked = join(dir, "file")
    await writeFile(blocked, "")
    const { fetchImpl } = fakeFetch({ "https://linear.app/favicon.ico": image(ICO) })
    const icons = makeToolIconStore({ dir: blocked, fetchImpl })
    expect((await icons.site("https://linear.app", "light"))?.contentType).toBe("image/x-icon")
  })

  it("shares one fetch between concurrent requests", async () => {
    const harness = await store({ "https://linear.app/favicon.ico": image(ICO) })
    const [one, two] = await Promise.all([
      harness.icons.site("https://linear.app", "light"),
      harness.icons.site("https://linear.app", "light")
    ])
    expect(one).toEqual(two)
    expect(harness.requested()).toEqual(["https://linear.app/", "https://linear.app/favicon.ico"])
  })
})

describe("MCP server icons", () => {
  const sourcesFor =
    (sources: Record<string, McpIconSources>) =>
    async (id: string): Promise<McpIconSources | undefined> =>
      sources[id]

  it("uses the server's own icons first, matching the appearance and its origin", async () => {
    const light = await png(64)
    const dark = await png(32)
    const harness = await store(
      {
        "https://linear.app/light.png": image(light),
        "https://linear.app/dark.png": image(dark),
        "https://tracker.example/elsewhere.png": image(light)
      },
      {
        mcpSources: sourcesFor({
          linear: {
            url: "https://mcp.linear.app/mcp",
            icons: [
              { src: "https://tracker.example/elsewhere.png", sizes: ["64x64"] },
              { src: "https://linear.app/light.png", sizes: ["64x64"], theme: "light" },
              { src: "https://linear.app/dark.png", sizes: ["any"], theme: "dark" },
              { src: "https://linear.app/plain.png" }
            ]
          }
        })
      }
    )
    const lightIcon = await harness.icons.mcp("linear", undefined, "light")
    expect((await sharp(lightIcon!.data).metadata()).width).toBe(64)
    const darkIcon = await harness.icons.mcp("linear", undefined, "dark")
    expect((await sharp(darkIcon!.data).metadata()).width).toBe(32)
    // Icons off the server's domain are never fetched.
    expect(harness.requested()).not.toContain("https://tracker.example/elsewhere.png")
  })

  it("decodes inline data URI icons", async () => {
    const encoded = `data:image/svg+xml,${encodeURIComponent(SVG)}`
    const base64 = `data:image/png;base64,${(await png(8)).toString("base64")}`
    const harness = await store(
      {},
      {
        mcpSources: sourcesFor({
          svg: { icons: [{ src: encoded }] },
          png: { icons: [{ src: base64 }] },
          broken: { icons: [{ src: "data:image/svg+xml,%E0%A4%A" }, { src: "data:nocomma" }] },
          huge: {
            icons: [
              {
                src: `data:image/png;base64,${Buffer.alloc(TOOL_ICON_MAX_BYTES + 1).toString("base64")}`
              }
            ]
          }
        })
      }
    )
    expect((await harness.icons.mcp("svg", undefined, "light"))?.contentType).toBe("image/png")
    expect((await harness.icons.mcp("png", undefined, "light"))?.contentType).toBe("image/png")
    expect(await harness.icons.mcp("broken", undefined, "light")).toBeUndefined()
    expect(await harness.icons.mcp("huge", undefined, "light")).toBeUndefined()
    expect(harness.requested()).toEqual([])
  })

  it("falls back to the brand's site, the server's website, its domain, then its own origin", async () => {
    const harness = await store(
      { "https://mcp.example.dev/favicon.ico": image(ICO) },
      {
        mcpSources: sourcesFor({
          sentry: { url: "https://mcp.sentry.dev/mcp", websiteUrl: "https://docs.sentry.dev/mcp" },
          custom: { url: "https://mcp.example.dev/mcp", websiteUrl: "ftp://example.dev" },
          odd: { url: "https://mcp.example.dev/mcp", websiteUrl: "not a url" }
        })
      }
    )
    expect(await harness.icons.mcp("sentry", undefined, "light")).toBeUndefined()
    expect(harness.requested().filter((url) => url.endsWith("/"))).toEqual([
      "https://sentry.io/",
      "https://docs.sentry.dev/",
      "https://sentry.dev/",
      "https://mcp.sentry.dev/"
    ])
    expect((await harness.icons.mcp("custom", undefined, "light"))?.contentType).toBe(
      "image/x-icon"
    )
    expect((await harness.icons.mcp("odd", undefined, "dark"))?.contentType).toBe("image/x-icon")
  })

  it("resolves servers this machine lacks by the host the transcript recorded", async () => {
    const harness = await store(
      { "https://linear.app/favicon.ico": image(ICO) },
      {
        mcpSources: async () => {
          throw new Error("unknown server")
        }
      }
    )
    expect((await harness.icons.mcp("gone", "mcp.linear.app", "light"))?.contentType).toBe(
      "image/x-icon"
    )
    expect(await harness.icons.mcp("gone", "bad host", "light")).toBeUndefined()
    expect(await harness.icons.mcp("gone", undefined, "light")).toBeUndefined()
    const bare = await store({})
    expect(await bare.icons.mcp("stdio", undefined, "light")).toBeUndefined()
    expect(bare.requested()).toEqual([])
  })

  it("replaces a favicon stand-in once the live server reports usable icons", async () => {
    let live: McpIconSources = { url: "https://mcp.linear.app/mcp" }
    const harness = await store(
      {
        "https://linear.app/favicon.ico": image(ICO),
        "https://linear.app/own.png": image(await png(64))
      },
      { mcpSources: async () => live }
    )
    expect((await harness.icons.mcp("linear", undefined, "light"))?.contentType).toBe(
      "image/x-icon"
    )
    expect((await harness.icons.mcp("linear", undefined, "light"))?.contentType).toBe(
      "image/x-icon"
    )
    expect(harness.refreshes).toHaveLength(0)

    live = { ...live, icons: [{ src: "https://linear.app/own.png" }] }
    expect((await harness.icons.mcp("linear", undefined, "light"))?.contentType).toBe(
      "image/x-icon"
    )
    await harness.refreshes[0]
    expect((await harness.icons.mcp("linear", undefined, "light"))?.contentType).toBe("image/png")
    expect(harness.refreshes).toHaveLength(1)
  })

  it("stops retrying a server whose own icons are all unusable", async () => {
    const live: McpIconSources = {
      url: "https://mcp.linear.app/mcp",
      icons: [{ src: "https://tracker.example/x.png" }, { src: "https://linear.app/missing.png" }]
    }
    const harness = await store(
      { "https://linear.app/favicon.ico": image(ICO) },
      { mcpSources: async () => live }
    )
    expect((await harness.icons.mcp("linear", undefined, "light"))?.contentType).toBe(
      "image/x-icon"
    )
    expect((await harness.icons.mcp("linear", undefined, "light"))?.contentType).toBe(
      "image/x-icon"
    )
    expect(harness.refreshes).toHaveLength(0)
  })
})
