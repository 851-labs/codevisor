import { execFile } from "node:child_process"
import { mkdir, mkdtemp, readFile, rm, stat, utimes, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { afterEach, describe, expect, it } from "vitest"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import {
  browserNativeMessagingDirectories,
  browserUserDataRoots,
  installBrowserNativeHost,
  installServerNativeHost
} from "./browser-native-host-install.js"
import { readNativeHostSecret } from "./browser-native-host.js"

const temporaryDirectories: Array<string> = []

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true }))
  )
})

describe("browser native messaging directories", () => {
  it.each([
    [
      "darwin",
      [
        "Library/Application Support/Google/Chrome",
        "Library/Application Support/Google/Chrome Canary",
        "Library/Application Support/Arc/User Data",
        "Library/Application Support/BraveSoftware/Brave-Browser",
        "Library/Application Support/Microsoft Edge"
      ]
    ],
    ["linux", [".config/google-chrome", ".config/chromium", ".config/BraveSoftware/Brave-Browser"]]
  ] as const)("targets only the %s browsers that have a profile root", async (platform, roots) => {
    const home = await temporaryDirectory()
    for (const root of roots) await mkdir(join(home, root), { recursive: true })

    const directories = browserNativeMessagingDirectories(home, platform)

    expect(directories.toSorted()).toEqual(
      roots.map((root) => join(home, root, "NativeMessagingHosts")).toSorted()
    )
    expect(browserUserDataRoots(home, platform).length).toBeGreaterThan(roots.length)
  })

  it("has no browser directories on platforms without Browser Use", () => {
    expect(browserUserDataRoots("/home", "win32")).toEqual([])
  })
})

describe("native host installation", () => {
  it("installs a launcher and a host manifest for the Codevisor extension in each browser", async () => {
    const root = await temporaryDirectory()
    const dataDir = join(root, "data dir's")
    const chrome = join(root, "Chrome", "NativeMessagingHosts")
    const arc = join(root, "Arc", "User Data", "NativeMessagingHosts")

    const installation = installBrowserNativeHost(options(root, dataDir, [chrome, arc]))

    expect(installation.manifests).toEqual([
      join(chrome, "com.codevisor.host.json"),
      join(arc, "com.codevisor.host.json")
    ])
    for (const manifest of installation.manifests) {
      expect(JSON.parse(await readFile(manifest, "utf8"))).toEqual({
        name: "com.codevisor.host",
        description: "Connects the Codevisor Chrome extension to the Codevisor app.",
        path: installation.launcher,
        type: "stdio",
        allowed_origins: [`chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}/`]
      })
    }
    expect(installation.launcher).toBe(
      join(dataDir, "browser", "native-host", "com.codevisor.host")
    )
    expect((await stat(installation.launcher)).mode & 0o777).toBe(0o700)
    expect(readNativeHostSecret(dataDir)).toMatch(/^[0-9a-f]{64}$/)
  })

  it("launches the host with node, the host script, and the data directory", async () => {
    const root = await temporaryDirectory()
    const dataDir = join(root, "data dir's")
    const script = join(root, "print-args.mjs")
    await writeFile(script, "console.log(JSON.stringify(process.argv.slice(2)))\n")

    const { launcher } = installBrowserNativeHost({
      ...options(root, dataDir, []),
      hostScript: script
    })
    const { stdout } = await promisify(execFile)(launcher, [
      `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}/`
    ])

    expect(JSON.parse(stdout)).toEqual([
      dataDir,
      `chrome-extension://${CODEVISOR_BROWSER_EXTENSION_ID}/`
    ])
  })

  it("leaves current files untouched and repairs missing or stale ones", async () => {
    const root = await temporaryDirectory()
    const chrome = join(root, "Chrome", "NativeMessagingHosts")
    const settings = options(root, join(root, "data"), [chrome])
    const first = installBrowserNativeHost(settings)
    const [manifest] = first.manifests
    const secret = readNativeHostSecret(settings.dataDir)
    const installedAt = new Date("2026-01-01T00:00:00Z")
    await utimes(manifest!, installedAt, installedAt)

    installBrowserNativeHost(settings)
    expect((await stat(manifest!)).mtime).toEqual(installedAt)

    await rm(manifest!)
    await writeFile(first.launcher, "#!/bin/sh\nexit 1\n")
    installBrowserNativeHost({ ...settings, nodePath: "/moved/node" })

    expect(JSON.parse(await readFile(manifest!, "utf8")).path).toBe(first.launcher)
    expect(await readFile(first.launcher, "utf8")).toContain("'/moved/node'")
    expect(readNativeHostSecret(settings.dataDir)).toBe(secret)
  })
})

describe("server native host installation", () => {
  it("installs the app's host into every detected browser", async () => {
    const home = await temporaryDirectory()
    await mkdir(join(home, ".config", "google-chrome"), { recursive: true })

    const installation = installServerNativeHost(join(home, "data"), {
      env: {},
      home,
      platform: "linux"
    })

    expect(installation.hostName).toBe("com.codevisor.host")
    expect(installation.manifests).toEqual([
      join(home, ".config", "google-chrome", "NativeMessagingHosts", "com.codevisor.host.json")
    ])
    expect(await readFile(installation.launcher, "utf8")).toContain(
      join("native-host", "codevisor-native-host.mjs")
    )
  })

  it("keeps development servers out of the real browsers unless pointed at a throwaway one", async () => {
    const home = await temporaryDirectory()
    await mkdir(join(home, ".config", "google-chrome"), { recursive: true })
    const throwaway = join(home, "throwaway", "NativeMessagingHosts")

    const untouched = installServerNativeHost(join(home, "data"), {
      env: { CODEVISOR_DEV_WORKTREE: "fudge" },
      home,
      platform: "linux"
    })
    const pointed = installServerNativeHost(join(home, "data"), {
      env: { CODEVISOR_DEV_WORKTREE: "fudge", CODEVISOR_NATIVE_MESSAGING_DIRS: `${throwaway}:` },
      home,
      platform: "linux"
    })

    expect(untouched.manifests).toEqual([])
    expect(pointed.manifests).toEqual([join(throwaway, "com.codevisor.dev.fudge.json")])
  })
})

const options = (root: string, dataDir: string, manifestDirectories: ReadonlyArray<string>) => ({
  dataDir,
  hostName: "com.codevisor.host",
  nodePath: process.execPath,
  hostScript: join(root, "host.mjs"),
  manifestDirectories
})

const temporaryDirectory = async (): Promise<string> => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-native-install-"))
  temporaryDirectories.push(directory)
  return directory
}
