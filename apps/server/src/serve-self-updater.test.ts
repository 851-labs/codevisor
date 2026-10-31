import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { makeDatabase, type CodevisorDatabaseService } from "@codevisor/db"
import {
  APP_UPDATE_CHANNEL_FILE,
  APP_UPDATE_FEED_FILE,
  DEFAULT_ALPHA_SERVER_MANIFEST_URL,
  DEFAULT_STABLE_SERVER_MANIFEST_URL,
  DEFAULT_SPARKLE_FEED_URL
} from "@codevisor/updater"
import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { makeSelfUpdater } from "./serve-self-updater.js"

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

const requestURL = (input: Parameters<typeof fetch>[0]): string =>
  input instanceof Request ? input.url : input.toString()

describe("makeSelfUpdater release resolution", () => {
  let dataDir: string
  let db: CodevisorDatabaseService
  let feedStatus: number
  let fetch: ReturnType<typeof vi.fn<typeof globalThis.fetch>>

  beforeEach(async () => {
    dataDir = mkdtempSync(join(tmpdir(), "codevisor-self-updater-"))
    db = await Effect.runPromise(makeDatabase({ filename: ":memory:", serverId: "self-updater" }))
    feedStatus = 200
    fetch = vi.fn<typeof globalThis.fetch>(async (input) => {
      const url = requestURL(input)
      if (url === DEFAULT_ALPHA_SERVER_MANIFEST_URL)
        return new Response(manifest("0.1.102-alpha.661", 661))
      if (url === DEFAULT_STABLE_SERVER_MANIFEST_URL) return new Response(manifest("0.1.101", 644))
      if (url === customFeedURL || url === DEFAULT_SPARKLE_FEED_URL) {
        return new Response(feed, { status: feedStatus })
      }
      throw new Error(`unexpected fetch ${url}`)
    })
  })

  afterEach(async () => {
    await Effect.runPromise(db.close)
    vi.unstubAllEnvs()
    rmSync(dataDir, { recursive: true, force: true })
  })

  const requestedURLs = () => fetch.mock.calls.map((call) => requestURL(call[0]))

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
    expect(requestedURLs()).toEqual([DEFAULT_SPARKLE_FEED_URL])
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
    vi.stubEnv("CODEVISOR_APP_HOSTED", "")
    const instance = updater()

    const alpha = await instance.check({ channel: "alpha" })
    const afterAlpha = fetch.mock.calls.length
    const stable = await instance.check({ channel: "stable" })
    const afterStable = fetch.mock.calls.length
    const alphaAgain = await instance.check({ channel: "alpha" })

    expect([alpha.latestVersion, stable.latestVersion, alphaAgain.latestVersion]).toEqual([
      "0.1.102-alpha.661",
      "0.1.101",
      "0.1.102-alpha.661"
    ])
    expect(afterStable).toBeGreaterThan(afterAlpha)
    expect(fetch).toHaveBeenCalledTimes(afterStable)

    await instance.check({ channel: "alpha", force: true })
    expect(fetch).toHaveBeenCalledTimes(afterStable + afterAlpha)
  })
})
