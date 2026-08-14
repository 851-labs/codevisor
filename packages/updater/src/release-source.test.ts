import { mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  DEFAULT_ALPHA_SERVER_MANIFEST_URL,
  DEFAULT_LEGACY_RELEASE_BASE_URL,
  DEFAULT_STABLE_SERVER_MANIFEST_URL,
  fetchAlphaServerRelease,
  fetchLatestGitHubServerRelease,
  fetchStableServerRelease,
  fetchLegacyServerRelease,
  fetchLatestServerRelease,
  isNewerRelease,
  parseSha256,
  sha256File,
  serverReleaseFromGitHub,
  serverReleaseFromManifest
} from "./release-source.js"

const temporaryRoots: Array<string> = []

afterEach(() => {
  vi.unstubAllGlobals()
  for (const root of temporaryRoots.splice(0)) {
    rmSync(root, { force: true, recursive: true })
  }
})

describe("serverReleaseFromGitHub", () => {
  it("selects the target archive and checksum from a stable release", () => {
    expect(
      serverReleaseFromGitHub(
        {
          tag_name: "v0.4.0",
          html_url: "https://github.example/release",
          draft: false,
          prerelease: false,
          assets: [
            {
              name: "codevisor-server-darwin-arm64.tar.gz",
              browser_download_url: "https://github.example/server.tar.gz"
            },
            {
              name: "codevisor-server-darwin-arm64.tar.gz.sha256",
              browser_download_url: "https://github.example/server.tar.gz.sha256"
            }
          ]
        },
        "darwin-arm64"
      )
    ).toEqual({
      version: "0.4.0",
      archiveURL: "https://github.example/server.tar.gz",
      checksumURL: "https://github.example/server.tar.gz.sha256",
      releasePageURL: "https://github.example/release"
    })
  })

  it("does not accept prereleases", () => {
    expect(
      serverReleaseFromGitHub(
        { tag_name: "v0.4.0-rc.1", prerelease: true, assets: [] },
        "linux-x64"
      )
    ).toBeUndefined()
  })

  it("rejects malformed releases and missing target assets", () => {
    expect(serverReleaseFromGitHub({ tag_name: 4, assets: [] }, "linux-x64")).toBeUndefined()
    expect(serverReleaseFromGitHub({ tag_name: "v0.4.0" }, "linux-x64")).toBeUndefined()
    expect(
      serverReleaseFromGitHub(
        {
          tag_name: "v0.4.0",
          assets: [{ name: "different.tar.gz", browser_download_url: 42 }]
        },
        "linux-x64"
      )
    ).toBeUndefined()
  })
})

describe("GitHub and compatibility fetches", () => {
  it("fetches and parses a stable GitHub release", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
          tag_name: "v0.4.0",
          html_url: 42,
          assets: [
            {
              name: "codevisor-server-linux-x64.tar.gz",
              browser_download_url: "https://github.example/server.tar.gz"
            }
          ]
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )

    await expect(
      fetchLatestGitHubServerRelease({
        repository: "example/codevisor",
        target: "linux-x64",
        fetch
      })
    ).resolves.toEqual({
      version: "0.4.0",
      archiveURL: "https://github.example/server.tar.gz",
      checksumURL: undefined,
      releasePageURL: undefined
    })
  })

  it("uses the first-party stable manifest by default", async () => {
    const fetch = vi.fn<typeof globalThis.fetch>().mockResolvedValue(
      new Response(
        JSON.stringify({
          version: "0.4.0",
          targets: {
            "linux-x64": {
              archiveURL: "https://updates.example/server.tar.gz",
              checksumURL: "https://updates.example/server.tar.gz.sha256"
            }
          }
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      )
    )
    vi.stubGlobal("fetch", fetch)

    await expect(fetchLatestServerRelease({ target: "linux-x64" })).resolves.toEqual({
      version: "0.4.0",
      archiveURL: "https://updates.example/server.tar.gz",
      checksumURL: "https://updates.example/server.tar.gz.sha256",
      releasePageURL: undefined
    })
    expect(fetch).toHaveBeenCalledWith(
      DEFAULT_STABLE_SERVER_MANIFEST_URL,
      expect.objectContaining({
        headers: expect.objectContaining({ "cache-control": "no-cache" })
      })
    )
  })

  it("falls back through GitHub to the frozen bridge", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response("unavailable", { status: 503 }))
      .mockResolvedValueOnce(new Response("rate limited", { status: 403 }))
      .mockResolvedValueOnce(
        new Response('{"version":"v0.3.0"}', {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )

    await expect(
      fetchLatestServerRelease({
        repository: "example/codevisor",
        legacyBaseURL: "https://releases.example/codevisor",
        target: "linux-x64",
        fetch
      })
    ).resolves.toEqual({
      version: "0.3.0",
      archiveURL: "https://releases.example/codevisor/v0.3.0/codevisor-server-linux-x64.tar.gz",
      checksumURL:
        "https://releases.example/codevisor/v0.3.0/codevisor-server-linux-x64.tar.gz.sha256"
    })
  })

  it("uses GitHub when the first-party manifest has no matching target", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response('{"version":"0.4.0","targets":{}}', { status: 200 }))
      .mockResolvedValueOnce(
        new Response(
          JSON.stringify({
            tag_name: "v0.4.0",
            assets: [
              {
                name: "codevisor-server-linux-x64.tar.gz",
                browser_download_url: "https://github.example/server.tar.gz"
              }
            ]
          }),
          { status: 200 }
        )
      )

    await expect(
      fetchLatestServerRelease({
        repository: "example/codevisor",
        target: "linux-x64",
        fetch
      })
    ).resolves.toEqual({
      version: "0.4.0",
      archiveURL: "https://github.example/server.tar.gz",
      checksumURL: undefined,
      releasePageURL: undefined
    })
  })

  it("uses the bridge when GitHub returns no matching target", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response('{"version":"0.4.0","targets":{}}', { status: 200 }))
      .mockResolvedValueOnce(
        new Response('{"tag_name":"v0.4.0","assets":[]}', {
          status: 200,
          headers: { "Content-Type": "application/json" }
        })
      )
      .mockResolvedValueOnce(new Response('{"version":"v0.3.0"}', { status: 200 }))

    await expect(
      fetchLatestServerRelease({
        legacyBaseURL: "https://releases.example/codevisor",
        target: "linux-x64",
        fetch
      })
    ).resolves.toMatchObject({ version: "0.3.0" })
  })

  it("handles missing and malformed compatibility manifests", async () => {
    const missing = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValue(new Response("", { status: 404 }))
    await expect(
      fetchLegacyServerRelease({
        baseURL: "https://releases.example/codevisor",
        target: "linux-x64",
        fetch: missing
      })
    ).resolves.toBeUndefined()

    const malformed = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValue(new Response('{"version":42}', { status: 200 }))
    await expect(
      fetchLegacyServerRelease({
        baseURL: "https://releases.example/codevisor",
        target: "linux-x64",
        fetch: malformed
      })
    ).resolves.toBeUndefined()
  })

  it("uses the production compatibility URL when GitHub is unavailable", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response("unavailable", { status: 503 }))
      .mockResolvedValueOnce(new Response("unavailable", { status: 503 }))
      .mockResolvedValueOnce(new Response('{"version":"0.3.0"}', { status: 200 }))
    vi.stubGlobal("fetch", fetch)

    await fetchLatestServerRelease({ target: "linux-x64" })

    expect(fetch.mock.calls[2]?.[0]).toBe(`${DEFAULT_LEGACY_RELEASE_BASE_URL}/latest.json`)
  })

  it("exposes the lower-level GitHub error", async () => {
    await expect(
      fetchLatestGitHubServerRelease({
        repository: "example/codevisor",
        target: "linux-x64",
        fetch: vi
          .fn<typeof globalThis.fetch>()
          .mockResolvedValue(new Response("no", { status: 500 }))
      })
    ).rejects.toThrow("GitHub release lookup failed: HTTP 500")
  })

  it("rejects a malformed first-party manifest", async () => {
    await expect(
      fetchStableServerRelease({
        target: "linux-x64",
        fetch: vi
          .fn<typeof globalThis.fetch>()
          .mockResolvedValue(new Response('{"version":"0.4.0","targets":{}}', { status: 200 }))
      })
    ).resolves.toBeUndefined()
  })

  it("accepts optional first-party release metadata", () => {
    expect(
      serverReleaseFromManifest(
        {
          version: "v0.4.0",
          releasePageURL: "https://codevisor.dev/releases/0.4.0",
          targets: {
            "linux-x64": { archiveURL: "https://updates.example/server.tar.gz" }
          }
        },
        "linux-x64"
      )
    ).toEqual({
      version: "0.4.0",
      archiveURL: "https://updates.example/server.tar.gz",
      checksumURL: undefined,
      releasePageURL: "https://codevisor.dev/releases/0.4.0"
    })
  })
})

const manifestResponse = (body: unknown): Response =>
  new Response(JSON.stringify(body), {
    status: 200,
    headers: { "Content-Type": "application/json" }
  })

const alphaManifest = {
  version: "0.5.0-alpha.7",
  buildNumber: 57,
  targets: {
    "linux-x64": { archiveURL: "https://updates.example/alpha/server.tar.gz" }
  }
}

const stableManifest = {
  version: "0.4.0",
  buildNumber: 50,
  targets: {
    "linux-x64": { archiveURL: "https://updates.example/stable/server.tar.gz" }
  }
}

describe("alpha channel", () => {
  it("compares releases by build number when both sides have one", () => {
    expect(
      isNewerRelease(
        { version: "0.5.0-alpha.7", buildNumber: 57 },
        { version: "0.5.0", buildNumber: 50 }
      )
    ).toBe(true)
    expect(
      isNewerRelease(
        { version: "0.5.0", buildNumber: 50 },
        { version: "0.5.0-alpha.7", buildNumber: 57 }
      )
    ).toBe(false)
    // Same build is never an update.
    expect(
      isNewerRelease({ version: "0.5.0", buildNumber: 57 }, { version: "0.4.0", buildNumber: 57 })
    ).toBe(false)
    // Either side missing a build number falls back to version comparison.
    expect(isNewerRelease({ version: "0.5.0" }, { version: "0.4.0", buildNumber: 57 })).toBe(true)
    expect(isNewerRelease({ version: "0.4.0", buildNumber: 57 }, { version: "0.5.0" })).toBe(false)
  })

  it("parses the manifest build number and ignores malformed ones", () => {
    expect(serverReleaseFromManifest(alphaManifest, "linux-x64")).toMatchObject({
      version: "0.5.0-alpha.7",
      buildNumber: 57
    })
    expect(
      serverReleaseFromManifest({ ...alphaManifest, buildNumber: 57.5 }, "linux-x64")?.buildNumber
    ).toBeUndefined()
  })

  it("reads the alpha manifest from its default URL with the global fetch", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValue(manifestResponse(alphaManifest))
    vi.stubGlobal("fetch", fetch)
    await expect(fetchAlphaServerRelease({ target: "linux-x64" })).resolves.toMatchObject({
      version: "0.5.0-alpha.7",
      buildNumber: 57
    })
    expect(fetch.mock.calls[0]?.[0]).toBe(DEFAULT_ALPHA_SERVER_MANIFEST_URL)
  })

  it("surfaces alpha manifest lookup failures", async () => {
    await expect(
      fetchAlphaServerRelease({
        target: "linux-x64",
        fetch: vi
          .fn<typeof globalThis.fetch>()
          .mockResolvedValue(new Response("no", { status: 500 }))
      })
    ).rejects.toThrow("Alpha server manifest lookup failed: HTTP 500")
  })

  it("prefers the newer of the alpha and stable manifests", async () => {
    const alphaWins = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(manifestResponse(alphaManifest))
      .mockResolvedValueOnce(manifestResponse(stableManifest))
    await expect(
      fetchLatestServerRelease({ channel: "alpha", target: "linux-x64", fetch: alphaWins })
    ).resolves.toMatchObject({ version: "0.5.0-alpha.7" })

    // A stable cut after the last alpha outranks it and must be offered.
    const stableWins = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(manifestResponse({ ...alphaManifest, buildNumber: 40 }))
      .mockResolvedValueOnce(manifestResponse(stableManifest))
    await expect(
      fetchLatestServerRelease({ channel: "alpha", target: "linux-x64", fetch: stableWins })
    ).resolves.toMatchObject({ version: "0.4.0" })
  })

  it("keeps working when either manifest is missing", async () => {
    // No alpha manifest published yet: stable still resolves.
    const alphaMissing = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response("missing", { status: 404 }))
      .mockResolvedValueOnce(manifestResponse(stableManifest))
    await expect(
      fetchLatestServerRelease({ channel: "alpha", target: "linux-x64", fetch: alphaMissing })
    ).resolves.toMatchObject({ version: "0.4.0" })

    // Stable manifest outage: the alpha release still resolves.
    const stableMissing = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(manifestResponse(alphaManifest))
      .mockResolvedValueOnce(new Response("unavailable", { status: 503 }))
    await expect(
      fetchLatestServerRelease({ channel: "alpha", target: "linux-x64", fetch: stableMissing })
    ).resolves.toMatchObject({ version: "0.5.0-alpha.7" })

    // Stable manifest resolves but without the target: the alpha still wins.
    const stableNoTarget = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(manifestResponse(alphaManifest))
      .mockResolvedValueOnce(manifestResponse({ version: "0.4.0", targets: {} }))
      .mockResolvedValueOnce(new Response("rate limited", { status: 403 }))
    await expect(
      fetchLatestServerRelease({
        channel: "alpha",
        repository: "example/codevisor",
        target: "linux-x64",
        fetch: stableNoTarget
      })
    ).resolves.toMatchObject({ version: "0.5.0-alpha.7" })
  })

  it("falls back through GitHub when both manifests are unavailable", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValueOnce(new Response("missing", { status: 404 }))
      .mockResolvedValueOnce(new Response("unavailable", { status: 503 }))
      .mockResolvedValueOnce(
        manifestResponse({
          tag_name: "v0.4.0",
          assets: [
            {
              name: "codevisor-server-linux-x64.tar.gz",
              browser_download_url: "https://github.example/server.tar.gz"
            }
          ]
        })
      )
    await expect(
      fetchLatestServerRelease({
        channel: "alpha",
        repository: "example/codevisor",
        target: "linux-x64",
        fetch
      })
    ).resolves.toMatchObject({ version: "0.4.0" })
  })

  it("never touches the alpha manifest on the stable channel", async () => {
    const fetch = vi
      .fn<typeof globalThis.fetch>()
      .mockResolvedValue(manifestResponse(stableManifest))
    await fetchLatestServerRelease({ channel: "stable", target: "linux-x64", fetch })
    expect(fetch.mock.calls.map((call) => call[0])).toEqual([DEFAULT_STABLE_SERVER_MANIFEST_URL])
  })
})

describe("checksums", () => {
  it("accepts standard checksum sidecars", () => {
    const digest = "A".repeat(64)
    expect(parseSha256(`${digest}  archive.tar.gz\n`)).toBe(digest.toLowerCase())
    expect(parseSha256("not-a-checksum")).toBeUndefined()
  })

  it("hashes files without buffering release archives in memory", async () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-release-source-"))
    temporaryRoots.push(root)
    const path = join(root, "archive")
    writeFileSync(path, "hello")

    await expect(sha256File(path)).resolves.toBe(
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
    )
    await expect(sha256File(join(root, "missing"))).rejects.toThrow()
  })
})
