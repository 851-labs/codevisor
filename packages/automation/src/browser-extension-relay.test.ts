import { EventEmitter } from "node:events"
import { mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { crc32 } from "node:zlib"

import { afterEach, describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import type { BrowserExtensionSocket } from "./browser-extension-relay.js"
import {
  browserExtensionArchivePath,
  browserExtensionPath,
  CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL,
  createBrowserExtensionArchive,
  EXTENSION_READY_PROBE_MS,
  makeBrowserExtensionRelay,
  openBrowserExtensionDevelopmentFolder,
  openBrowserExtensionDevelopmentInstaller,
  openBrowserExtensionDevelopmentPage,
  openBrowserExtensionWebStore,
  prepareBrowserExtension
} from "./browser-extension-relay.js"
import { expectRecord } from "./unknown-values.js"

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
    const extension = join(runtime, "packages", "automation", "resources", "browser-extension")
    await mkdir(extension, { recursive: true })
    await writeFile(join(extension, "manifest.json"), "{}")

    expect(
      browserExtensionPath({
        moduleDirectory: join(runtime, "packages", "automation", "dist"),
        workingDirectory: "/"
      })
    ).toBe(extension)
  })

  it("replaces a damaged earlier extension instead of copying over it", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-extension-replace-"))
    temporaryDirectories.push(root)
    const extension = join(root, "browser", "extension")
    await mkdir(extension, { recursive: true })
    await writeFile(join(extension, "popup.js"), "")
    await writeFile(join(extension, "retired.js"), "old")

    expect(prepareBrowserExtension(root, "http://127.0.0.1:61234")).toBe(extension)
    expect((await readFile(join(extension, "popup.js"), "utf8")).length).toBeGreaterThan(0)
    await expect(readFile(join(extension, "retired.js"))).rejects.toThrow()
    prepareBrowserExtension(root, "http://127.0.0.1:61234")
    const siblings = await readdir(join(root, "browser"))
    expect(siblings.filter((name) => /\.(next|stale)-/.test(name))).toEqual([])
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
    const manifest: unknown = JSON.parse(await readFile(join(extension, "manifest.json"), "utf8"))

    expect(manifest).toMatchObject({
      name: "Codevisor (mirrlees)",
      description: "Control Chrome with Codevisor.",
      icons: { "16": "icons/16.png", "32": "icons/32.png", "128": "icons/128.png" },
      permissions: expect.arrayContaining(["alarms"]),
      action: {
        default_title: "Codevisor (mirrlees)",
        default_popup: "popup.html",
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
    expect(archive.toString("utf8")).toContain("Copy Diagnostics")
    expect(archive.toString("utf8")).toContain("RECONNECT_MAX_DELAY_MS")
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
    const launch = vi.fn(async () => undefined)

    await openBrowserExtensionDevelopmentInstaller(extension, {
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
    const launch = vi.fn(async () => undefined)
    const options = { platform: "darwin" as const, chromePath: chrome, launch }

    await openBrowserExtensionDevelopmentFolder(extension, options)
    expect(launch.mock.calls).toEqual([["open", ["-a", "Finder", extension]]])

    launch.mockClear()
    await openBrowserExtensionDevelopmentPage(extension, options)
    expect(launch.mock.calls).toEqual([
      ["open", ["-b", "com.google.Chrome", "chrome://extensions/"]]
    ])
  })

  it("opens the production extension in the Chrome Web Store", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-browser-web-store-"))
    temporaryDirectories.push(root)
    const chrome = join(root, "Google Chrome.app")
    await mkdir(chrome)
    const launch = vi.fn(async () => undefined)

    await openBrowserExtensionWebStore({ platform: "darwin", chromePath: chrome, launch })

    expect(launch.mock.calls).toEqual([
      ["open", ["-b", "com.google.Chrome", CODEVISOR_BROWSER_EXTENSION_WEB_STORE_URL]]
    ])
  })

  it("reports a missing opener to the caller instead of crashing the server", async () => {
    const emptyPath = await mkdtemp(join(tmpdir(), "codevisor-no-openers-"))
    temporaryDirectories.push(emptyPath)
    vi.stubEnv("PATH", emptyPath)
    try {
      await expect(openBrowserExtensionWebStore({ platform: "linux" })).rejects.toThrow(
        /Could not open xdg-open: .*ENOENT/
      )
    } finally {
      vi.unstubAllEnvs()
    }
  })
})

describe("portable browser extension archive", () => {
  it("refuses a missing manifest before publishing an archive", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-archive-missing-"))
    temporaryDirectories.push(root)
    expect(() => createBrowserExtensionArchive(root)).toThrow(
      "The Codevisor Chrome extension is missing"
    )
    expect(await readdir(root)).toEqual([])
  })

  it("uses fallback names and sanitizes manifest names without changing file contents", async () => {
    const parent = await mkdtemp(join(tmpdir(), "codevisor-archive-names-"))
    temporaryDirectories.push(parent)
    const root = join(parent, "extension")
    await mkdir(root)
    for (const [manifest, name] of [
      ["{}", "Codevisor.zip"],
      ['{"name":"  "}', "Codevisor.zip"],
      ['{"name":" /A:B\\\\C/ "}', "-A-B-C-.zip"]
    ]) {
      await writeFile(join(root, "manifest.json"), manifest!)
      expect(browserExtensionArchivePath(root)).toBe(join(root, "..", name!))
      const archive = createBrowserExtensionArchive(root)
      expect(archive).toBe(join(root, "..", name!))
      const bytes = await readFile(archive)
      expect(bytes.includes(Buffer.from(manifest!))).toBe(true)
    }
  })

  it("publishes a deterministic store-only ZIP with valid headers, offsets and CRCs", async () => {
    const parent = await mkdtemp(join(tmpdir(), "codevisor-archive-records-"))
    temporaryDirectories.push(parent)
    const root = join(parent, "extension")
    await mkdir(join(root, "nested"), { recursive: true })
    await Promise.all([
      writeFile(join(root, "manifest.json"), "{}"),
      writeFile(join(root, "empty"), ""),
      writeFile(join(root, "nested", "é.txt"), "123456789"),
      writeFile(join(root, ".DS_Store"), "omit"),
      writeFile(join(root, "nested", ".DS_Store"), "omit")
    ])
    await symlink(join(root, "manifest.json"), join(root, "linked.json"))
    const archive = createBrowserExtensionArchive(root)
    const bytes = await readFile(archive)
    expect((await stat(archive)).mode & 0o777).toBe(0o600)
    expect((await readdir(parent)).toSorted()).toEqual(["Codevisor.zip", "extension"])
    const expected = [
      { name: "empty", text: "", offset: 0 },
      { name: "manifest.json", text: "{}", offset: 35 },
      { name: "nested/é.txt", text: "123456789", offset: 80 }
    ]
    for (const entry of expected) {
      const offset = entry.offset
      expect(bytes.readUInt32LE(offset)).toBe(0x04034b50)
      expect(bytes.subarray(offset + 4, offset + 14).toString("hex")).toBe("14000008000000002150")
      const size = Buffer.byteLength(entry.text)
      const nameSize = Buffer.byteLength(entry.name)
      expect(bytes.readUInt32LE(offset + 14)).toBe(crc32(entry.text))
      expect(bytes.readUInt32LE(offset + 18)).toBe(size)
      expect(bytes.readUInt32LE(offset + 22)).toBe(size)
      expect(bytes.readUInt16LE(offset + 26)).toBe(nameSize)
      expect(bytes.readUInt16LE(offset + 28)).toBe(0)
      expect(bytes.subarray(offset + 30, offset + 30 + nameSize).toString()).toBe(entry.name)
      expect(bytes.subarray(offset + 30 + nameSize, offset + 30 + nameSize + size).toString()).toBe(
        entry.text
      )
    }
    let central = 132
    for (const entry of expected) {
      expect(bytes.readUInt32LE(central)).toBe(0x02014b50)
      expect(bytes.subarray(central + 4, central + 16).toString("hex")).toBe(
        "140314000008000000002150"
      )
      expect(bytes.readUInt32LE(central + 16)).toBe(crc32(entry.text))
      expect(bytes.readUInt32LE(central + 20)).toBe(Buffer.byteLength(entry.text))
      expect(bytes.readUInt32LE(central + 24)).toBe(Buffer.byteLength(entry.text))
      const nameSize = Buffer.byteLength(entry.name)
      expect(bytes.readUInt16LE(central + 28)).toBe(nameSize)
      expect(bytes.subarray(central + 30, central + 42)).toEqual(Buffer.alloc(12))
      expect(bytes.readUInt32LE(central + 42)).toBe(entry.offset)
      expect(bytes.subarray(central + 46, central + 46 + nameSize).toString()).toBe(entry.name)
      central += 46 + nameSize
    }
    expect(central).toBe(301)
    expect(bytes.subarray(central).toString("hex")).toBe(
      "504b05060000000003000300a9000000840000000000"
    )
    expect(bytes.length).toBe(323)
  })
})

class FakeExtensionSocket extends EventEmitter implements BrowserExtensionSocket {
  readyState: number = WebSocket.OPEN
  readonly received: Array<string> = []

  constructor(private unheardMessages = 0) {
    super()
  }

  send(message: string): void {
    const { id, method } = expectRecord(JSON.parse(message), "relay command")
    this.received.push(String(method))
    if (this.unheardMessages > 0) {
      this.unheardMessages -= 1
      return
    }
    this.emit("message", Buffer.from(JSON.stringify({ id, result: { targetInfos: [] } })))
  }
  close(): void {
    this.readyState = WebSocket.CLOSED
    this.emit("close")
  }
  terminate(): void {
    this.close()
  }
}

describe("browser extension relay readiness", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("reports the extension connected only once it answers commands", async () => {
    vi.useFakeTimers()
    const relay = makeBrowserExtensionRelay()
    const socket = new FakeExtensionSocket(1)
    const { promise: ready, resolve } = Promise.withResolvers<void>()
    const connected = vi.fn((value: boolean) => {
      if (value) resolve()
    })
    relay.onConnectionChange(connected)
    relay.accept(socket)
    await vi.advanceTimersByTimeAsync(EXTENSION_READY_PROBE_MS - 1)
    expect(relay.connected()).toBe(false)
    expect(connected).not.toHaveBeenCalled()

    await vi.advanceTimersByTimeAsync(1)
    await ready
    expect(connected).toHaveBeenCalledWith(true)
    expect(socket.received).toEqual(["Target.getTargets", "Target.getTargets"])
    await relay.close()
  })
})
