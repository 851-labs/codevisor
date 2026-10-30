import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { HarnessDefinition } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import { waitForLifecycleSettle, fakeAgentRuntime } from "./harness-lifecycle-test-support.js"
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
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"

afterEach(cleanupLifecycleTests)

const executable = (path: string) => {
  mkdirSync(join(path, ".."), { recursive: true })
  writeFileSync(path, "#!/bin/sh\n")
  chmodSync(path, 0o755)
  return path
}

describe("harness lifecycle bundled desktop apps", () => {
  it("reports and updates the bundled desktop app for dual installs", async () => {
    const db = await makeDb()
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
      agents: fakeAgentRuntime({
        catalog: [definition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
        ]),
        refreshEnvironment: Effect.void
      }),
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
    const [decorated] = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Users/dev/.local/bin/fake-cli", "1.0.0")
    ])
    expect(decorated?.lifecycle).toBeUndefined()
    expect(decorated?.updateInfo?.installedVersion).toBe("1.0.0")
  })

  it("reports no bundled app when the bundle is absent, outside an app, or off darwin", async () => {
    const db = await makeDb()
    const root = mkdtempSync(join(tmpdir(), "codevisor-app-"))
    directories.push(root)
    const bundled = executable(join(root, "FakeChat.app", "Contents", "Resources", "codex"))
    const loose = executable(join(root, "bin", "codex"))
    const lifecycleFor = (fallback: string, platform: NodeJS.Platform) =>
      makeHarnessLifecycleManager({
        agents: fakeAgentRuntime({
          catalog: [
            {
              ...installableDefinition,
              fallbackPaths: [fallback],
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
          ],
          discoverHarnesses: Effect.succeed([]),
          refreshEnvironment: Effect.void
        }),
        db,
        platform,
        resolveEnv: async () => ({})
      })
    const absent = lifecycleFor("/nonexistent/FakeChat.app/Contents/Resources/codex", "darwin")
    await expect(absent.bundledAppInfo("fake-cli")).resolves.toBeUndefined()
    await expect(absent.beginBundledAppUpdate("fake-cli")).rejects.toThrow(/no bundled/)
    await expect(lifecycleFor(loose, "darwin").bundledAppInfo("fake-cli")).resolves.toBeUndefined()
    await expect(lifecycleFor(bundled, "linux").bundledAppInfo("fake-cli")).resolves.toBeUndefined()
  })

  it("refuses app-bundle swaps off darwin", async () => {
    const db = await makeDb()
    const { terminal } = fakeTerminal()
    const lifecycle = makeHarnessLifecycleManager({
      agents: fakeAgentRuntime({
        catalog: [appBundleDefinition],
        discoverHarnesses: Effect.succeed([
          harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
        ]),
        refreshEnvironment: Effect.void
      }),
      db,
      platform: "linux",
      realpath: (path) => path,
      resolveEnv: async () => ({}),
      terminal
    })
    await expect(lifecycle.applyUpdate("fake-cli")).resolves.toBe(false)
    const [decorated] = await lifecycle.decorateHarnesses([
      harness("fake-cli", "/Applications/ChatGPT.app/Contents/Resources/codex")
    ])
    expect(decorated?.lifecycle?.error).toMatch(/desktop app/)
  })
})
