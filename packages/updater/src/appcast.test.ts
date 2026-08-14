import { describe, expect, it } from "vitest"
import { parseAppcast, selectLatestAppcastItem } from "./appcast.js"

/// Trimmed from the real codex-app-prod feed (arm64) — shape preserved:
/// full-zip enclosure plus delta enclosures nested in <sparkle:deltas>.
const fixture = `<?xml version='1.0' encoding='utf-8'?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Codex</title>
    <item>
      <title>26.715.52143</title>
      <pubDate>Mon, 20 Jul 2026 07:13:17 +0000</pubDate>
      <sparkle:version>5591</sparkle:version>
      <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
      <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.715.52143.zip" length="568247110" type="application/octet-stream" sparkle:edSignature="w/wmUijNN5Bq6EgFSc+oIGLgJp5dVejZ8Nuy0nPN+59bBbSy4MQVKQ6dPdcFEB5oO3BZDC790+HS6SHFmPNBBg==" />
      <sparkle:deltas>
        <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT5591-5551-arm64.delta" sparkle:deltaFrom="5551" length="656234" type="application/octet-stream" sparkle:edSignature="deltasig==" />
      </sparkle:deltas>
    </item>
    <item>
      <title>26.715.31925</title>
      <sparkle:version>5551</sparkle:version>
      <sparkle:shortVersionString>26.715.31925</sparkle:shortVersionString>
      <enclosure url="https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.715.31925.zip" length="568215546" type="application/octet-stream" sparkle:edSignature="j5EfO5/ys+QNKdlWIzO+j4F1E7UnGj70UXoNkX3+76JJeZdx1L/Cw+L3GGu9/CHjyX6k4ZscesHrvieqTaf5BQ==" />
    </item>
  </channel>
</rss>`

describe("appcast", () => {
  it("parses items with the full-zip enclosure, skipping deltas", () => {
    const items = parseAppcast(fixture)
    expect(items).toHaveLength(2)
    expect(items[0]).toEqual({
      build: "5591",
      edSignature:
        "w/wmUijNN5Bq6EgFSc+oIGLgJp5dVejZ8Nuy0nPN+59bBbSy4MQVKQ6dPdcFEB5oO3BZDC790+HS6SHFmPNBBg==",
      length: 568_247_110,
      minimumSystemVersion: "12.0",
      shortVersion: "26.715.52143",
      url: "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.715.52143.zip"
    })
    // The delta URL must never appear as an item's enclosure.
    expect(items.every((item) => !item.url.endsWith(".delta"))).toBe(true)
  })

  it("selects the newest item by short version", () => {
    const items = parseAppcast(fixture)
    expect(selectLatestAppcastItem(items)?.shortVersion).toBe("26.715.52143")
    // Order independence: reversed feed picks the same item.
    expect(selectLatestAppcastItem([...items].reverse())?.shortVersion).toBe("26.715.52143")
  })

  it("parses items with only an enclosure URL, omitting absent fields", () => {
    const bare = `<rss><channel>
      <item><enclosure url="https://example.com/bare.zip" /></item>
      <item><p>no enclosure at all</p></item>
      <item><enclosure type="application/octet-stream" /></item>
    </rss></channel>`
    expect(parseAppcast(bare)).toEqual([{ url: "https://example.com/bare.zip" }])
    // Version-less items still resolve by feed order.
    expect(selectLatestAppcastItem(parseAppcast(bare))?.url).toBe("https://example.com/bare.zip")
  })

  it("returns nothing for feeds without items", () => {
    expect(parseAppcast("<rss></rss>")).toEqual([])
    expect(selectLatestAppcastItem([])).toBeUndefined()
  })
})
