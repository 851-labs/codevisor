import type { AppcastItem } from "./appcast.js"
import { parseAppcast } from "./appcast.js"
import type { ServerRelease, ServerUpdateChannel } from "./release-source.js"

export const DEFAULT_SPARKLE_FEED_URL = "https://updates.codevisor.dev/appcast-arm64.xml"

const buildNumber = (item: AppcastItem): number | undefined => {
  if (item.build === undefined || !/^\d+$/.test(item.build)) return undefined
  const value = Number(item.build)
  return Number.isSafeInteger(value) ? value : undefined
}

export const selectSparkleRelease = (
  items: ReadonlyArray<AppcastItem>,
  channel: ServerUpdateChannel
): AppcastItem | undefined => {
  let latest: { readonly item: AppcastItem; readonly build: number } | undefined
  for (const item of items) {
    if (item.channel !== undefined && !(channel === "alpha" && item.channel === "alpha")) continue
    const build = buildNumber(item)
    if (build === undefined) continue
    if (latest === undefined || build > latest.build) latest = { item, build }
  }
  return latest?.item
}

export const serverReleaseFromAppcastItem = (item: AppcastItem): ServerRelease | undefined => {
  const build = buildNumber(item)
  if (item.shortVersion === undefined || build === undefined) return undefined
  const version =
    item.channel === "alpha" && !item.shortVersion.includes("-")
      ? `${item.shortVersion}-alpha.${build}`
      : item.shortVersion
  return {
    version,
    buildNumber: build,
    archiveURL: item.url,
    ...(item.link === undefined ? {} : { releasePageURL: item.link })
  }
}

export const fetchLatestSparkleRelease = async (options: {
  readonly feedURL: string
  readonly channel: ServerUpdateChannel
  readonly fetch?: typeof globalThis.fetch | undefined
}): Promise<ServerRelease | undefined> => {
  const fetcher = options.fetch ?? globalThis.fetch
  const response = await fetcher(options.feedURL, {
    headers: { "cache-control": "no-cache" },
    cache: "no-store",
    signal: AbortSignal.timeout(10_000)
  })
  if (!response.ok) return undefined
  const item = selectSparkleRelease(parseAppcast(await response.text()), options.channel)
  return item === undefined ? undefined : serverReleaseFromAppcastItem(item)
}
