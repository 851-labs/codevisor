import { isNewerVersion } from "./harness-update-sources.js"

export interface AppcastItem {
  readonly shortVersion?: string
  readonly build?: string
  readonly minimumSystemVersion?: string
  readonly channel?: string
  readonly link?: string
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

export const parseAppcast = (xml: string): ReadonlyArray<AppcastItem> => {
  const items: Array<AppcastItem> = []
  for (const match of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    /* v8 ignore next */
    const block = (match[1] ?? "").replace(/<sparkle:deltas>[\s\S]*?<\/sparkle:deltas>/g, "")
    const enclosure = /<enclosure\b[^>]*\/?>/.exec(block)?.[0]
    if (enclosure === undefined) continue
    const url = attribute(enclosure, "url")
    if (url === undefined) continue
    const shortVersion = tagText(block, "sparkle:shortVersionString")
    const build = tagText(block, "sparkle:version")
    const minimumSystemVersion = tagText(block, "sparkle:minimumSystemVersion")
    const channel = tagText(block, "sparkle:channel")
    const link = tagText(block, "link")
    const edSignature = attribute(enclosure, "sparkle:edSignature")
    const length = Number(attribute(enclosure, "length"))
    items.push({
      url,
      ...(shortVersion === undefined ? {} : { shortVersion }),
      ...(build === undefined ? {} : { build }),
      ...(minimumSystemVersion === undefined ? {} : { minimumSystemVersion }),
      ...(channel === undefined ? {} : { channel }),
      ...(link === undefined ? {} : { link }),
      ...(Number.isFinite(length) && length > 0 ? { length } : {}),
      ...(edSignature === undefined ? {} : { edSignature })
    })
  }
  return items
}

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
