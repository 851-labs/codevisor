import type { HarnessDefinition } from "@codevisor/agent-runtime"
import { makeHarnessLifecycleManager, appBundlePath } from "./harness-lifecycle.js"
import type { FetchLike } from "@codevisor/updater"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupLifecycleTests,
  makeDb,
  harness,
  agentsStub,
  npmDefinition,
  jsonResponse
} from "./harness-lifecycle-test-support.js"

afterEach(cleanupLifecycleTests)

describe("harness lifecycle update detection", () => {
  it("checks, persists, decorates, and emits only on change", async () => {
    const db = await makeDb()
    const fetchImpl: FetchLike = async (url) =>
      url.includes("registry.npmjs.org")
        ? jsonResponse({ "dist-tags": { latest: "2.0.0" } })
        : jsonResponse({}, 404)
    const events: Array<unknown> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [npmDefinition],
        [harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")]
      ),
      db,
      fetchImpl,
      home: "/Users/dev",
      realpath: (path) => path
    })
    lifecycle.subscribe((event) => events.push(event))

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes).toEqual([
      {
        harnessId: "fake-cli",
        info: expect.objectContaining({
          installOrigin: "curl",
          installedVersion: "1.0.0",
          latestVersion: "2.0.0",
          source: "npm",
          updateAvailable: true
        })
      }
    ])
    expect(events).toHaveLength(1)

    // Same knowledge on a re-check → no duplicate event.
    await lifecycle.checkForUpdates(true)
    expect(events).toHaveLength(1)

    // Persisted state survives a fresh manager (server restart).
    const rebooted = makeHarnessLifecycleManager({
      agents: agentsStub([npmDefinition], []),
      db,
      fetchImpl
    })
    const decorated = await rebooted.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
    ])
    expect(decorated[0]?.updateInfo).toMatchObject({
      latestVersion: "2.0.0",
      updateAvailable: true
    })
  })

  it("suppresses unforced re-checks inside the cache window", async () => {
    const db = await makeDb()
    let calls = 0
    const fetchImpl: FetchLike = async () => {
      calls += 1
      return jsonResponse({ "dist-tags": { latest: "2.0.0" } })
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [npmDefinition],
        [harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")]
      ),
      db,
      fetchImpl,
      home: "/Users/dev",
      realpath: (path) => path
    })
    await lifecycle.checkForUpdates(true)
    expect(calls).toBe(1)
    await expect(lifecycle.checkForUpdates()).resolves.toEqual([])
    expect(calls).toBe(1)
  })

  it("compares app-bundle installs against the app version via the sparkle feed", async () => {
    const db = await makeDb()
    const appcast = `<rss><channel><item>
      <sparkle:version>5591</sparkle:version>
      <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
      <enclosure url="https://example.com/ChatGPT.zip" length="1" sparkle:edSignature="sig==" />
    </item></channel></rss>`
    const definition: HarnessDefinition = {
      detectBinaries: ["codex"],
      id: "codex-like",
      name: "Codex Like",
      provider: "codex",
      symbolName: "terminal",
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          }
        ]
      }
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [definition],
        [
          // The CLI's own version channel runs ahead — it must NOT be used.
          harness(
            "codex-like",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "0.145.0-alpha.18"
          )
        ]
      ),
      db,
      fetchImpl: async () => jsonResponse(appcast),
      home: "/Users/dev",
      platform: "darwin",
      readBundleShortVersion: async (bundlePath) =>
        bundlePath === "/Applications/ChatGPT.app" ? "26.715.31925" : undefined,
      realpath: (path) => path
    })

    const outcomes = await lifecycle.checkForUpdates(true)
    expect(outcomes[0]?.info).toMatchObject({
      channel: "app",
      installOrigin: "appBundle",
      installedVersion: "26.715.31925",
      latestVersion: "26.715.52143",
      source: "sparkle",
      updateAvailable: true
    })
  })

  it("skips app-bundle checks off darwin and harnesses without sources", async () => {
    const db = await makeDb()
    const definition: HarnessDefinition = {
      detectBinaries: ["codex"],
      id: "codex-like",
      name: "Codex Like",
      provider: "codex",
      symbolName: "terminal",
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          }
        ]
      }
    }
    const lifecycle = makeHarnessLifecycleManager({
      agents: agentsStub(
        [definition],
        [harness("codex-like", "/Applications/ChatGPT.app/Contents/Resources/codex")]
      ),
      db,
      fetchImpl: async () => jsonResponse({}, 500),
      platform: "linux",
      realpath: (path) => path
    })
    await expect(lifecycle.checkForUpdates(true)).resolves.toEqual([])
  })

  it("derives the bundle path from the binary path", () => {
    expect(appBundlePath("/Applications/ChatGPT.app/Contents/Resources/codex")).toBe(
      "/Applications/ChatGPT.app"
    )
    expect(appBundlePath("/usr/local/bin/codex")).toBeUndefined()
  })
})
