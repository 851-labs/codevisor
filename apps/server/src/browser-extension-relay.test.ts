import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  browserExtensionArchivePath,
  browserExtensionPath,
  CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL,
  openBrowserExtensionDevelopmentFolder,
  openBrowserExtensionDevelopmentInstaller,
  openBrowserExtensionDevelopmentPage,
  openBrowserExtensionWebStore,
  prepareBrowserExtension
} from "./browser-extension-relay.js"

const temporaryDirectories: Array<string> = []

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true }))
  )
})

describe("browser extension development installer", () => {
  it("finds extension resources from a packaged runtime launched outside its directory", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-packaged-browser-"))
    temporaryDirectories.push(root)
    const runtime = join(root, "darwin-arm64")
    const extension = join(runtime, "apps", "server", "resources", "browser-extension")
    await mkdir(extension, { recursive: true })
    await writeFile(join(extension, "manifest.json"), "{}")

    expect(
      browserExtensionPath({
        moduleDirectory: runtime,
        workingDirectory: "/"
      })
    ).toBe(extension)
  })

  it("brands the prepared extension for the current development worktree", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-browser-branding-"))
    temporaryDirectories.push(root)
    const generatedIcons = join(root, "generated-icons")
    await mkdir(generatedIcons)
    await Promise.all([
      writeFile(join(generatedIcons, "icon_16x16.png"), "dev-16"),
      writeFile(join(generatedIcons, "icon_16x16@2x.png"), "dev-32"),
      writeFile(join(generatedIcons, "icon_128x128.png"), "dev-128")
    ])

    const extension = prepareBrowserExtension(root, "http://127.0.0.1:61234", {
      worktreeName: "mirrlees",
      iconDirectory: generatedIcons
    })
    const manifest = JSON.parse(await readFile(join(extension, "manifest.json"), "utf8")) as {
      name: string
      description: string
      icons: Record<string, string>
      action: { default_title: string; default_icon: Record<string, string> }
    }

    expect(manifest).toMatchObject({
      name: "Codevisor (mirrlees)",
      description: "Control Chrome with Codevisor.",
      icons: { "16": "icons/16.png", "32": "icons/32.png", "128": "icons/128.png" },
      action: {
        default_title: "Codevisor (mirrlees)",
        default_icon: {
          "16": "icons/16.png",
          "32": "icons/32.png",
          "128": "icons/128.png"
        }
      }
    })
    await expect(readFile(join(extension, "icons", "16.png"), "utf8")).resolves.toBe("dev-16")
    await expect(readFile(join(extension, "icons", "32.png"), "utf8")).resolves.toBe("dev-32")
    await expect(readFile(join(extension, "icons", "128.png"), "utf8")).resolves.toBe("dev-128")
    const archive = await readFile(browserExtensionArchivePath(extension))
    expect(archive.subarray(0, 4).toString("hex")).toBe("504b0304")
    expect(archive.toString("utf8")).toContain("Codevisor (mirrlees)")
    expect(archive.toString("utf8")).toContain(
      "ws://127.0.0.1:61234/v1/browser-use/extension/socket"
    )
    expect(archive.toString("utf8")).toContain('"key"')
  })

  it("opens Chrome Extensions and the unpacked directory in Finder on macOS", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-browser-installer-"))
    temporaryDirectories.push(root)
    const extension = join(root, "Codevisor")
    const chrome = join(root, "Google Chrome.app")
    await mkdir(extension)
    await mkdir(chrome)
    await writeFile(join(extension, "manifest.json"), "{}")
    const launch = vi.fn()

    openBrowserExtensionDevelopmentInstaller(extension, {
      platform: "darwin",
      chromePath: chrome,
      launch
    })

    expect(launch.mock.calls).toEqual([
      ["open", ["-b", "com.google.Chrome", "chrome://extensions/"]],
      ["open", ["-a", "Finder", extension]]
    ])
  })

  it("can open the development folder and Chrome Extensions independently", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-browser-destinations-"))
    temporaryDirectories.push(root)
    const extension = join(root, "Codevisor")
    const chrome = join(root, "Google Chrome.app")
    await mkdir(extension)
    await mkdir(chrome)
    await writeFile(join(extension, "manifest.json"), "{}")
    const launch = vi.fn()
    const options = { platform: "darwin" as const, chromePath: chrome, launch }

    openBrowserExtensionDevelopmentFolder(extension, options)
    expect(launch.mock.calls).toEqual([["open", ["-a", "Finder", extension]]])

    launch.mockClear()
    openBrowserExtensionDevelopmentPage(extension, options)
    expect(launch.mock.calls).toEqual([
      ["open", ["-b", "com.google.Chrome", "chrome://extensions/"]]
    ])
  })

  it("opens the production extension in the Chrome Web Store", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-browser-web-store-"))
    temporaryDirectories.push(root)
    const chrome = join(root, "Google Chrome.app")
    await mkdir(chrome)
    const launch = vi.fn()

    openBrowserExtensionWebStore({ platform: "darwin", chromePath: chrome, launch })

    expect(launch.mock.calls).toEqual([
      ["open", ["-b", "com.google.Chrome", CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL]]
    ])
  })
})
