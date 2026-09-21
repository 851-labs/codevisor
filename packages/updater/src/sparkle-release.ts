import type { AppcastItem } from "./appcast.js"
import { parseAppcast } from "./appcast.js"
import type { ServerRelease, ServerUpdateChannel } from "./release-source.js"

/// Release resolution for app-hosted Macs, read from the Sparkle appcast
/// the host app installs from. The JSON server manifests and the appcast
/// are published by the same release job, but they are separate documents:
/// making the server's "latest" come from the appcast means the check and
/// the install can no longer disagree about what "newer" means.

/// The production feed for this architecture — the mirror of the app's
/// `SparkleUpdateController.feedURLString(for:)`. Used when the host app
/// has not written its feed URL (an app predating the handoff file).
export const defaultSparkleFeedURL = (arch: string = process.arch): string =>
  `https://updates.codevisor.dev/appcast-${arch === "x64" ? "x64" : "arm64"}.xml`

const buildNumber = (item: AppcastItem): number | undefined => {
  if (item.build === undefined || !/^\d+$/.test(item.build)) return undefined
  const value = Number(item.build)
  return Number.isSafeInteger(value) ? value : undefined
}

/// The item Sparkle would install from this feed on this channel: the
/// highest `sparkle:version` among items the channel allows. Sparkle's
/// rule (`allowedChannels`): items with no channel always qualify; an
/// item on the "alpha" channel only when alpha updates are enabled. Ties
/// keep feed order (Sparkle feeds are newest-first).
///
/// `minimumSystemVersion` is deliberately not checked: this server runs
/// inside the very bundle Sparkle updates, so every item the app can
/// publish for this machine is runnable here.
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

/// A release record for an appcast item. The version string matches what
/// the app shows for the same item (`AppUpdateModel.displayedVersion`):
/// alpha items carry the build as a prerelease suffix because successive
/// alphas share one marketing version. The archive is the app zip; an
/// app-hosted server never downloads it (the host app's Sparkle does).
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

/// Fetches the feed and resolves the release Sparkle would install.
/// Undefined when the feed answers with an error status or has no
/// qualifying item; a network failure propagates so the caller can fall
/// back to the manifests.
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
