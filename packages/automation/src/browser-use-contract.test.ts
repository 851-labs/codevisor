import { createHash } from "node:crypto"
import { rmSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { managedBrowserSandboxArguments } from "./browser-chromium.js"
import {
  browserExtensionInstallation,
  browserExtensionPath,
  CODEVISOR_BROWSER_EXTENSION_ID
} from "./browser-extension-relay.js"
import { browserUseTools } from "./browser-use-provider.js"
import { buildExecutionSource } from "./code-executor-source.js"
import { expectRecord, expectString } from "./unknown-values.js"

const toolProperties = (name: string) => {
  const tool = browserUseTools.find((candidate) => candidate.name === name)
  if (tool === undefined) throw new Error(`Missing Browser Use tool ${name}`)
  return Object.keys(tool.inputSchema.properties ?? {})
}

const directories: string[] = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { force: true, recursive: true })
})

describe("Browser Use tool contract", () => {
  it("disables Chromium's process sandbox only for containerized or root Linux", () => {
    expect(
      managedBrowserSandboxArguments({ platform: "linux", uid: 0, containerized: false })
    ).toEqual(["--no-sandbox"])
    expect(
      managedBrowserSandboxArguments({ platform: "linux", uid: 1_000, containerized: true })
    ).toEqual(["--no-sandbox"])
    expect(
      managedBrowserSandboxArguments({ platform: "linux", uid: 1_000, containerized: false })
    ).toEqual([])
    expect(
      managedBrowserSandboxArguments({ platform: "darwin", uid: 0, containerized: true })
    ).toEqual([])
  })

  it("keeps the bundled relay extension id stable", () => {
    const extension = browserExtensionPath()
    expect(extension).toBeDefined()
    const manifest = expectRecord(
      JSON.parse(readFileSync(join(extension!, "manifest.json"), "utf8")),
      "manifest"
    )
    const key = expectString(manifest.key, "manifest key")
    const digest = createHash("sha256").update(Buffer.from(key, "base64")).digest()
    const id = [...digest.subarray(0, 16)]
      .flatMap((byte) => [byte >> 4, byte & 15])
      .map((nibble) => String.fromCharCode(97 + nibble))
      .join("")
    expect(id).toBe(CODEVISOR_BROWSER_EXTENSION_ID)
    expect(manifest.permissions).toContain("debugger")
    expect(manifest.permissions).toEqual(
      expect.arrayContaining([
        "downloads",
        "offscreen",
        "clipboardRead",
        "clipboardWrite",
        "tabGroups"
      ])
    )
    expect(readFileSync(join(extension!, "offscreen.html"), "utf8")).toContain("offscreen.js")
    const connectPage = readFileSync(join(extension!, "connect.html"), "utf8")
    expect(connectPage).toContain("https://www.codevisor.dev/privacy")
    expect(connectPage).toContain("agent provider you selected in Codevisor")
  })

  it("distinguishes bundled extension files from an installed Chrome profile", () => {
    const home = mkdtempSync(join(tmpdir(), "codevisor-browser-extension-"))
    directories.push(home)
    expect(browserExtensionInstallation(home)).toMatchObject({ bundled: true, installed: false })

    expect(["darwin", "linux"]).toContain(process.platform)
    const profile =
      process.platform === "darwin"
        ? join(home, "Library", "Application Support", "Google", "Chrome", "Default")
        : join(home, ".config", "google-chrome", "Default")
    mkdirSync(profile, { recursive: true })
    writeFileSync(
      join(profile, "Preferences"),
      JSON.stringify({ extensions: { settings: { [CODEVISOR_BROWSER_EXTENSION_ID]: {} } } })
    )
    expect(browserExtensionInstallation(home)).toMatchObject({
      bundled: true,
      installed: true,
      profiles: [profile]
    })
  })

  it("rejects undeclared arguments on every tool", () => {
    for (const tool of browserUseTools) {
      expect(tool.inputSchema.additionalProperties).toBe(false)
    }
  })

  it("offers tabId only on tools that act on a tab", () => {
    for (const name of ["status", "use_backend", "request_extension_install"])
      expect(toolProperties(name)).not.toContain("tabId")
    expect(toolProperties("snapshot")).toContain("tabId")
  })

  it("declares every browser tool the execute sandbox's browser facade calls", () => {
    const declared = new Set(browserUseTools.map((tool) => tool.name))
    const called = new Set(
      [...buildExecutionSource("async () => 1").matchAll(/Tool\([^)']*'browser\.([\w.]+)'/g)].map(
        (match) => match[1]!
      )
    )
    expect(called).toContain("playwright.click")
    expect([...called].filter((name) => !declared.has(name))).toEqual([])
  })

  it("documents the native clipboard item shape", () => {
    const clipboardWrite = browserUseTools.find((candidate) => candidate.name === "clipboard.write")
    expect(clipboardWrite?.inputSchema).toMatchObject({
      properties: {
        items: {
          items: {
            properties: {
              entries: {
                items: {
                  properties: {
                    mimeType: { type: "string" },
                    text: { type: "string" },
                    base64: { type: "string" }
                  }
                }
              }
            }
          }
        }
      }
    })
  })
})
