import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import sharp from "sharp"
import { afterEach, describe, expect, it } from "vitest"

import { makeAppIconLoader, type RunCommand } from "./tool-icon-apps.js"
import { makeToolIconStore } from "./tool-icons.js"

const PNG = new Uint8Array([1, 2, 3])

/// A machine with `apps` installed (bundle path → Info.plist keys), where
/// Spotlight knows `indexed` and `sips` converts any `.icns` that exists.
const machine = (
  apps: Readonly<Record<string, Readonly<Record<string, string>>>>,
  indexed: ReadonlyArray<string> = []
) => {
  const commands: Array<string> = []
  const run: RunCommand = async (file, args) => {
    commands.push([file.split("/").at(-1), ...args].join(" "))
    if (file.endsWith("mdfind")) return `${indexed.join("\n")}\n`
    if (file.endsWith("plutil")) {
      const app = args[5]!.replace("/Contents/Info.plist", "")
      const value = apps[app]?.[args[1]!]
      if (value === undefined) throw new Error("no such key")
      return `${value}\n`
    }
    const icns = args[5]!
    const app = Object.keys(apps).find((path) => icns.startsWith(path))
    if (app === undefined || icns.includes("Missing")) throw new Error("sips: no such file")
    return ""
  }
  return { run, commands, readFile: async () => PNG }
}

const MUSIC = "/System/Applications/Music.app"

describe("app icons", () => {
  it("converts the reported app's own .icns", async () => {
    const host = machine({
      [MUSIC]: { CFBundleIdentifier: "com.apple.Music", CFBundleIconFile: "AppIcon" }
    })
    const load = makeAppIconLoader(host)
    expect(await load("com.apple.Music", MUSIC)).toEqual(PNG)
    expect(host.commands.at(-1)).toMatch(
      /^sips -s format png -Z 128 \/System\/Applications\/Music\.app\/Contents\/Resources\/AppIcon\.icns --out \/.+\/icon\.png$/
    )
    expect(host.commands.some((command) => command.startsWith("mdfind"))).toBe(false)
  })

  it("finds the bundle with Spotlight when the reported path is gone or another app", async () => {
    const host = machine(
      {
        "/Applications/Old.app": { CFBundleIdentifier: "com.example.other" },
        "/Applications/Broken.app": {
          CFBundleIdentifier: "com.example.notes",
          CFBundleIconFile: "Missing.icns"
        },
        "/Applications/Bare.app": { CFBundleIdentifier: "com.example.notes" },
        "/Applications/Notes.app": {
          CFBundleIdentifier: "com.example.notes",
          CFBundleIconFile: "Notes.icns"
        }
      },
      [
        "/Applications/Old.app",
        "/Users/me/notes.txt",
        "/Applications/Broken.app",
        "/Applications/Bare.app",
        "/Applications/Notes.app"
      ]
    )
    const load = makeAppIconLoader(host)
    expect(await load("com.example.notes", "/Applications/Old.app")).toEqual(PNG)
    expect(host.commands).toContain('mdfind kMDItemCFBundleIdentifier == "com.example.notes"')
    expect(host.commands.at(-1)).toContain("/Applications/Notes.app/Contents/Resources/Notes.icns")
  })

  it("refuses odd bundle IDs and answers nothing when the app isn't installed", async () => {
    const host = machine({})
    const load = makeAppIconLoader(host)
    expect(await load('x" || kMDItemDisplayName == "*', undefined)).toBeUndefined()
    expect(await load("plain", undefined)).toBeUndefined()
    expect(host.commands).toEqual([])
    expect(await load("com.example.gone", "relative/Gone.app")).toBeUndefined()
    expect(host.commands).toEqual(['mdfind kMDItemCFBundleIdentifier == "com.example.gone"'])
    const offline = makeAppIconLoader({
      run: async () => {
        throw new Error("mdfind unavailable")
      },
      readFile: async () => PNG
    })
    expect(await offline("com.example.gone", undefined)).toBeUndefined()
  })
})

describe("app icon store", () => {
  const directories: Array<string> = []
  afterEach(async () => {
    await Promise.all(directories.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
  })

  it("normalizes and caches an app's icon, and has none without a loader", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tool-icons-apps-"))
    directories.push(dir)
    const png = await sharp({
      create: { width: 256, height: 256, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 1 } }
    })
      .png()
      .toBuffer()
    const asked: Array<string> = []
    const icons = makeToolIconStore({
      dir,
      appIcon: async (bundleId, path) => {
        asked.push(`${bundleId} ${path}`)
        return bundleId === "com.apple.Music" ? new Uint8Array(png) : undefined
      }
    })
    const music = await icons.app("com.apple.Music", MUSIC)
    expect(music?.contentType).toBe("image/png")
    expect((await sharp(music!.data).metadata()).width).toBe(128)
    expect(await icons.app("com.apple.Music", undefined)).toEqual(music)
    expect(await icons.app("com.example.gone", undefined)).toBeUndefined()
    expect(asked).toEqual([`com.apple.Music ${MUSIC}`, "com.example.gone undefined"])

    expect(await makeToolIconStore({ dir }).app("com.apple.Music", MUSIC)).toBeUndefined()
  })
})
