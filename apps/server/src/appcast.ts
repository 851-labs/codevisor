import { isNewerVersion } from "./harness-update-sources.js"

/// Minimal Sparkle appcast reader for the ChatGPT/Codex app feed. Only the
/// fields the harness updater needs; delta enclosures are deliberately
/// ignored (the bundle swap always downloads the full zip).

export interface AppcastItem {
  /// sparkle:shortVersionString — the human version (CFBundleShortVersionString).
  readonly shortVersion?: string
  /// sparkle:version — the monotonically increasing build number.
  readonly build?: string
  readonly minimumSystemVersion?: string
  /// Full-zip enclosure.
  readonly url: string
  readonly length?: number
  readonly edSignature?: string
}

const tagText = (block: string, tag: string): string | undefined => {
  const match = new RegExp(`<${tag}>([^<]*)</${tag}>`).exec(block)
  const value = match?.[1]?.trim()
  return value === undefined || value.length === 0 ? undefined : value
}

const attribute = (element: string, name: string): string | undefined => {
  const match = new RegExp(`${name}="([^"]*)"`).exec(element)
  const value = match?.[1]
  return value === undefined || value.length === 0 ? undefined : value
}

/// Parses an appcast XML document into items, newest first by short version.
/// Regex-based on purpose: the feed is machine-generated RSS with a fixed
/// shape, and pulling in an XML parser for it isn't worth the dependency.
export const parseAppcast = (xml: string): ReadonlyArray<AppcastItem> => {
  const items: Array<AppcastItem> = []
  for (const match of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    // Strip delta enclosures so the enclosure scan below only sees the full
    // zip (deltas live inside <sparkle:deltas>…</sparkle:deltas>).
    /* v8 ignore next -- the capture group always exists on a match; ?? guards the type only. */
    const block = (match[1] ?? "").replace(/<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/g, "")
    const enclosure = /<enclosure\b[^>]*\/?>/.exec(block)?.[0]
    if (enclosure === undefined) continue
    const url = attribute(enclosure, "url")
    if (url === undefined) continue
    const shortVersion = tagText(block, "sparkle:shortVersionString")
    const build = tagText(block, "sparkle:version")
    const minimumSystemVersion = tagText(block, "sparkle:minimumSystemVersion")
    const edSignature = attribute(enclosure, "sparkle:edSignature")
    const length = Number(attribute(enclosure, "length"))
    items.push({
      url,
      ...(shortVersion === undefined ? {} : { shortVersion }),
      ...(build === undefined ? {} : { build }),
      ...(minimumSystemVersion === undefined ? {} : { minimumSystemVersion }),
      ...(Number.isFinite(length) && length > 0 ? { length } : {}),
      ...(edSignature === undefined ? {} : { edSignature })
    })
  }
  return items
}

/// The newest item in the feed by short version (falls back to feed order —
/// Sparkle feeds are newest-first by convention).
export const selectLatestAppcastItem = (
  items: ReadonlyArray<AppcastItem>
): AppcastItem | undefined => {
  let latest: AppcastItem | undefined
  for (const item of items) {
    if (latest === undefined) {
      latest = item
      continue
    }
    if (
      item.shortVersion !== undefined &&
      latest.shortVersion !== undefined &&
      isNewerVersion(item.shortVersion, latest.shortVersion)
    ) {
      latest = item
    }
  }
  return latest
}
