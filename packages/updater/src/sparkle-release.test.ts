import { describe, expect, it, vi } from "vitest"

import { parseAppcast } from "./appcast.js"
import {
  defaultSparkleFeedURL,
  fetchLatestSparkleRelease,
  selectSparkleRelease,
  serverReleaseFromAppcastItem
} from "./sparkle-release.js"

/// Shaped like scripts/release/update-appcast.mjs output: one feed per
/// architecture, alpha items tagged with <sparkle:channel>, stable items
/// untagged, newest first.
const item = (build: number, version: string, alpha: boolean): string => `
    <item>
      <title>Codevisor ${version}${alpha ? " Alpha" : ""}</title>
      <link>https://github.com/851-labs/codevisor/releases/tag/v${version}${alpha ? `-alpha.${build}` : ""}</link>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      ${alpha ? "<sparkle:channel>alpha</sparkle:channel>" : ""}
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <enclosure url="https://updates.codevisor.dev/updates/${build}/Codevisor-macOS-arm64.zip" length="1" type="application/octet-stream" sparkle:edSignature="sig" />
    </item>`

const feed = (...items: ReadonlyArray<string>): string =>
  `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Codevisor Updates</title>${items.join("")}
  </channel>
</rss>`

const mixedFeed = feed(
  item(661, "0.1.102", true),
  item(660, "0.1.102", true),
  item(644, "0.1.101", false),
  item(640, "0.1.101", true)
)

describe("selectSparkleRelease", () => {
  it("on stable, ignores alpha items even when they are newer", () => {
    const selected = selectSparkleRelease(parseAppcast(mixedFeed), "stable")
    expect(selected?.build).toBe("644")
    expect(selected?.channel).toBeUndefined()
  })

  it("on alpha, takes the highest build across both channels", () => {
    expect(selectSparkleRelease(parseAppcast(mixedFeed), "alpha")?.build).toBe("661")
    // A stable cut after the last alpha still wins for alpha followers.
    const stableNewest = feed(item(700, "0.1.103", false), item(661, "0.1.102", true))
    expect(selectSparkleRelease(parseAppcast(stableNewest), "alpha")?.build).toBe("700")
  })

  it("compares build numbers numerically, not by feed order or version string", () => {
    const reordered = feed(item(660, "0.1.102", true), item(661, "0.1.102", true))
    expect(selectSparkleRelease(parseAppcast(reordered), "alpha")?.build).toBe("661")
    const digits = feed(item(99, "0.1.9", false), item(100, "0.1.10", false))
    expect(selectSparkleRelease(parseAppcast(digits), "stable")?.build).toBe("100")
  })

  it("skips items without a numeric build and unknown channels", () => {
    const odd = `<rss><channel>
      <item><sparkle:version>abc</sparkle:version><enclosure url="https://example.com/a.zip" /></item>
      <item><enclosure url="https://example.com/b.zip" /></item>
      <item><sparkle:version>7</sparkle:version><sparkle:channel>nightly</sparkle:channel><enclosure url="https://example.com/n.zip" /></item>
      <item><sparkle:version>5</sparkle:version><enclosure url="https://example.com/c.zip" /></item>
    </channel></rss>`
    expect(selectSparkleRelease(parseAppcast(odd), "alpha")?.build).toBe("5")
    expect(selectSparkleRelease([], "alpha")).toBeUndefined()
    // Digits alone are not enough: the build must be a safe integer.
    const huge = [{ url: "https://example.com/h.zip", build: "99999999999999999999" }]
    expect(selectSparkleRelease(huge, "alpha")).toBeUndefined()
  })
})

describe("serverReleaseFromAppcastItem", () => {
  it("derives the alpha version string the app displays", () => {
    const [alpha] = parseAppcast(feed(item(661, "0.1.102", true)))
    expect(serverReleaseFromAppcastItem(alpha!)).toEqual({
      version: "0.1.102-alpha.661",
      buildNumber: 661,
      archiveURL: "https://updates.codevisor.dev/updates/661/Codevisor-macOS-arm64.zip",
      releasePageURL: "https://github.com/851-labs/codevisor/releases/tag/v0.1.102-alpha.661"
    })
  })

  it("keeps stable and already-suffixed versions as published", () => {
    const [stable] = parseAppcast(feed(item(644, "0.1.101", false)))
    expect(serverReleaseFromAppcastItem(stable!)?.version).toBe("0.1.101")
    const suffixed = parseAppcast(feed(item(3, "1.0.0-rc.1", true)))[0]!
    expect(serverReleaseFromAppcastItem(suffixed)?.version).toBe("1.0.0-rc.1")
  })

  it("requires a short version and a numeric build", () => {
    expect(
      serverReleaseFromAppcastItem({ url: "https://example.com/a.zip", build: "5" })
    ).toBeUndefined()
    expect(
      serverReleaseFromAppcastItem({ url: "https://example.com/a.zip", shortVersion: "1.0" })
    ).toBeUndefined()
    expect(
      serverReleaseFromAppcastItem({
        url: "https://example.com/a.zip",
        shortVersion: "1.0",
        build: "5"
      })
    ).toEqual({ version: "1.0", buildNumber: 5, archiveURL: "https://example.com/a.zip" })
  })
})

describe("fetchLatestSparkleRelease", () => {
  it("reads the given feed without caching and resolves the channel's release", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(new Response(mixedFeed))
    const release = await fetchLatestSparkleRelease({
      feedURL: "https://updates.example.com/appcast-arm64.xml",
      channel: "alpha",
      fetch
    })
    expect(release?.buildNumber).toBe(661)
    expect(release?.version).toBe("0.1.102-alpha.661")
    expect(fetch).toHaveBeenCalledOnce()
    const [url, init] = fetch.mock.calls[0]!
    expect(url).toBe("https://updates.example.com/appcast-arm64.xml")
    expect(init?.cache).toBe("no-store")
  })

  it("is undefined on an error status or an empty feed, and throws on a network failure", async () => {
    const failing = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValue(new Response("", { status: 500 }))
    await expect(
      fetchLatestSparkleRelease({ feedURL: "https://x/feed.xml", channel: "alpha", fetch: failing })
    ).resolves.toBeUndefined()
    const empty = vi.fn<typeof globalThis.fetch>().mockResolvedValue(new Response(feed()))
    await expect(
      fetchLatestSparkleRelease({ feedURL: "https://x/feed.xml", channel: "alpha", fetch: empty })
    ).resolves.toBeUndefined()
    const offline = vi.fn<typeof globalThis.fetch>().mockRejectedValue(new Error("offline"))
    await expect(
      fetchLatestSparkleRelease({ feedURL: "https://x/feed.xml", channel: "alpha", fetch: offline })
    ).rejects.toThrow("offline")
  })
})

describe("fetchLatestSparkleRelease with the global fetch", () => {
  it("uses the global fetch when none is injected", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(new Response(mixedFeed))
    vi.stubGlobal("fetch", fetch)
    try {
      const release = await fetchLatestSparkleRelease({
        feedURL: "https://updates.example.com/appcast-arm64.xml",
        channel: "stable"
      })
      expect(release?.buildNumber).toBe(644)
      expect(fetch).toHaveBeenCalledOnce()
    } finally {
      vi.unstubAllGlobals()
    }
  })
})

describe("defaultSparkleFeedURL", () => {
  it("mirrors the app's per-architecture production feeds", () => {
    expect(defaultSparkleFeedURL("x64")).toBe("https://updates.codevisor.dev/appcast-x64.xml")
    expect(defaultSparkleFeedURL("arm64")).toBe("https://updates.codevisor.dev/appcast-arm64.xml")
    expect(defaultSparkleFeedURL()).toBe(defaultSparkleFeedURL(process.arch))
  })
})
