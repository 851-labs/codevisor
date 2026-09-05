import { waitForLifecycleSettle } from "./harness-lifecycle-test-support.js"
import type { AgentRuntimeService, HarnessDefinition } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupLifecycleTests,
  directories,
  makeDb,
  harness,
  jsonResponse,
  fakeTerminal,
  appBundleDefinition,
  installableDefinition
} from "./harness-lifecycle-test-support.js"

afterEach(cleanupLifecycleTests)

describe("harness lifecycle bundled desktop apps", () => {
  it("reports and updates the bundled desktop app for dual installs", async () => {
    const db = await makeDb()
    // A fake app bundle with an executable CLI inside, so the fallback-path
    // probe (accessSync X_OK) finds it like the real ChatGPT.app copy.
    const appDir = mkdtempSync(join(tmpdir(), "codevisor-app-"))
    directories.push(appDir)
    const bundle = join(appDir, "FakeChat.app")
    const resources = join(bundle, "Contents", "Resources")
    mkdirSync(resources, { recursive: true })
    const bundledBinary = join(resources, "codex")
    writeFileSync(bundledBinary, "#!/bin/sh\n")
    chmodSync(bundledBinary, 0o755)

    const appcast = `<rss><channel><item>
      <sparkle:shortVersionString>26.715.52143</sparkle:shortVersionString>
      <enclosure url="https://example.com/FakeChat.zip" length="1" sparkle:edSignature="sig==" />
    </item></channel></rss>`
    const definition: HarnessDefinition = {
      ...installableDefinition,
      fallbackPaths: [bundledBinary],
      update: {
        sources: [
          {
            apply: { kind: "appBundleSwap" },
            check: { appcastUrl: "https://example.com/appcast.xml", kind: "sparkle" },
            when: "appBundle"
          },
          {
            apply: { args: ["update"], kind: "selfUpdate" },
            check: { kind: "npm", packageName: "fake-cli" },
            when: "any"
          }
        ]
      }
    }
    const swaps: Array<string> = []
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [definition],
        // Primary install is the user's own CLI — NOT the bundle.
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      applyBundleSwap: async (options) => {
        swaps.push(options.bundlePath)
        return { installedVersion: "26.715.52143" }
      },
      db,
      fetchImpl: async (url) =>
        url.includes("appcast")
          ? jsonResponse(appcast)
          : jsonResponse({ "dist-tags": { latest: "1.0.0" } }),
      platform: "darwin",
      readBundleShortVersion: async (path) => (path === bundle ? "26.715.31925" : undefined),
      realpath: (path) => path,
      resolveEnv: async () => ({})
    })

    await expect(lifecycle.bundledAppInfo("fake-cli")).resolves.toEqual({
      appName: "FakeChat",
      bundlePath: bundle,
      installedVersion: "26.715.31925",
      latestVersion: "26.715.52143",
      updateAvailable: true
    })

    const settled = waitForLifecycleSettle(lifecycle)
    await lifecycle.beginBundledAppUpdate("fake-cli")
    await settled
    expect(swaps).toEqual([bundle])
  })

  it("reports no bundled app when the bundle is absent or off darwin", async () => {
    const db = await makeDb()
    const definition: HarnessDefinition = {
      ...installableDefinition,
      fallbackPaths: ["/nonexistent/FakeChat.app/Contents/Resources/codex"],
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
      agents: {
        catalog: [definition],
        discoverHarnesses: Effect.succeed([]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      db,
      platform: "darwin",
      resolveEnv: async () => ({})
    })
    await expect(lifecycle.bundledAppInfo("fake-cli")).resolves.toBeUndefined()
    await expect(lifecycle.beginBundledAppUpdate("fake-cli")).rejects.toThrow(/no bundled/)
  })

  it("refuses app-bundle swaps off darwin", async () => {
    const db = await makeDb()
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: {
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      } as unknown as AgentRuntimeService,
      db,
      platform: "linux",
      realpath: (path) => path,
      resolveEnv: async () => ({}),
      terminal
    })
    await expect(lifecycle.beginUpdate("fake-cli")).rejects.toThrow(/desktop app/)
  })
})
