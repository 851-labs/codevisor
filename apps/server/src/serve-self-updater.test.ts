import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  APP_UPDATE_CHANNEL_FILE,
  APP_UPDATE_FEED_FILE,
  DEFAULT_ALPHA_SERVER_MANIFEST_URL,
  DEFAULT_STABLE_SERVER_MANIFEST_URL,
  defaultSparkleFeedURL
} from "@codevisor/updater"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeSelfUpdater } from "./serve-self-updater.js"

/// The release documents the same publish job writes: the appcast Sparkle
/// installs from, and the JSON manifests standalone servers install from.
/// They disagree here on purpose — the manifest is one build ahead — so
/// each test shows which one an updater believes.
const feed = `<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
  <item>
    <link>https://github.com/851-labs/codevisor/releases/tag/v0.1.102-alpha.660</link>
    <sparkle:version>660</sparkle:version>
    <sparkle:shortVersionString>0.1.102</sparkle:shortVersionString>
    <sparkle:channel>alpha</sparkle:channel>
    <enclosure url="https://updates.codevisor.dev/updates/660/Codevisor-macOS-arm64.zip" />
  </item>
  <item>
    <sparkle:version>644</sparkle:version>
    <sparkle:shortVersionString>0.1.101</sparkle:shortVersionString>
    <enclosure url="https://updates.codevisor.dev/updates/644/Codevisor-macOS-arm64.zip" />
  </item>
</channel></rss>`

const manifest = (version: string, buildNumber: number): string =>
  JSON.stringify({
    version,
    buildNumber,
    targets: Object.fromEntries(
      ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64"].map((target) => [
        target,
        {
          archiveURL: `https://updates.codevisor.dev/updates/${buildNumber}/codevisor-server-${target}.tar.gz`
        }
      ])
    )
  })

const customFeedURL = "https://feeds.example.test/appcast-dev.xml"

const db = {
  getSyncEntries: () => Effect.succeed([]),
  setUpdateInfo: (info: unknown) => Effect.succeed(info)
} as unknown as CodevisorDatabaseService

describe("makeSelfUpdater release resolution", () => {
  let dataDir: string
  let feedStatus: number
  let fetch: ReturnType<typeof vi.fn<typeof globalThis.fetch>>

  beforeEach(() => {
    dataDir = mkdtempSync(join(tmpdir(), "codevisor-self-updater-"))
    feedStatus = 200
    fetch = vi.fn<typeof globalThis.fetch>(async (input) => {
      const url = String(input)
      if (url === DEFAULT_ALPHA_SERVER_MANIFEST_URL)
        return new Response(manifest("0.1.102-alpha.661", 661))
      if (url === DEFAULT_STABLE_SERVER_MANIFEST_URL) return new Response(manifest("0.1.101", 644))
      if (url === customFeedURL || url === defaultSparkleFeedURL()) {
        return new Response(feed, { status: feedStatus })
      }
      throw new Error(`unexpected fetch ${url}`)
    })
  })

  afterEach(() => {
    vi.unstubAllEnvs()
    rmSync(dataDir, { recursive: true, force: true })
  })

  const requestedURLs = () => fetch.mock.calls.map((call) => String(call[0]))

  const updater = () =>
    makeSelfUpdater({
      currentVersion: "0.1.102",
      currentBuildNumber: 659,
      db,
      dataDir,
      serveArgs: [],
      fetch
    })

  it("app-hosted: reports what Sparkle will install, not what the manifest says", async () => {
    vi.stubEnv("CODEVISOR_APP_HOSTED", "1")
    writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "alpha\n")
    writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), `${customFeedURL}\n`)

    const info = await updater().check({ channel: "alpha" })

    expect(info).toMatchObject({
      currentVersion: "0.1.102",
      currentBuildNumber: 659,
      latestVersion: "0.1.102-alpha.660",
      latestBuildNumber: 660,
      updateAvailable: true,
      channel: "alpha"
    })
    expect(requestedURLs()).toEqual([customFeedURL])
  })

  it("app-hosted: follows the machine's channel file when choosing from the feed", async () => {
    vi.stubEnv("CODEVISOR_APP_HOSTED", "1")
    writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "stable\n")
    writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), customFeedURL)

    // The client asked for alpha; the machine installs stable, so the
    // stable item is what "latest" means here (and it is not newer).
    const info = await updater().check({ channel: "alpha" })

    expect(info).toMatchObject({
      latestVersion: "0.1.101",
      latestBuildNumber: 644,
      updateAvailable: false,
      channel: "stable"
    })
  })

  it("app-hosted: uses this architecture's production feed when the app wrote none", async () => {
    vi.stubEnv("CODEVISOR_APP_HOSTED", "1")
    writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "alpha\n")

    const info = await updater().check({ channel: "alpha" })

    expect(info.latestBuildNumber).toBe(660)
    expect(requestedURLs()).toEqual([defaultSparkleFeedURL()])
  })

  it("app-hosted: falls back to the manifests when the feed is unavailable", async () => {
    vi.stubEnv("CODEVISOR_APP_HOSTED", "1")
    writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "alpha\n")
    writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), customFeedURL)
    feedStatus = 503

    const info = await updater().check({ channel: "alpha" })

    expect(info.latestBuildNumber).toBe(661)
    expect(requestedURLs()).toEqual([
      customFeedURL,
      DEFAULT_ALPHA_SERVER_MANIFEST_URL,
      DEFAULT_STABLE_SERVER_MANIFEST_URL
    ])
  })

  it("standalone: reads the manifests and never the appcast", async () => {
    vi.stubEnv("CODEVISOR_APP_HOSTED", "")
    writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), customFeedURL)

    const info = await updater().check({ channel: "alpha" })

    expect(info).toMatchObject({ latestVersion: "0.1.102-alpha.661", latestBuildNumber: 661 })
    expect(requestedURLs()).toEqual([
      DEFAULT_ALPHA_SERVER_MANIFEST_URL,
      DEFAULT_STABLE_SERVER_MANIFEST_URL
    ])
  })

  it("caches a check per channel until forced", async () => {
    vi.stubEnv("CODEVISOR_APP_HOSTED", "1")
    writeFileSync(join(dataDir, APP_UPDATE_CHANNEL_FILE), "alpha\n")
    writeFileSync(join(dataDir, APP_UPDATE_FEED_FILE), customFeedURL)
    const instance = updater()

    await instance.check({ channel: "alpha" })
    await instance.check({ channel: "alpha" })
    expect(fetch).toHaveBeenCalledTimes(1)

    await instance.check({ channel: "alpha", force: true })
    expect(fetch).toHaveBeenCalledTimes(2)
  })
})
