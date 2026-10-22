import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import { extensionNeedsUpdate } from "./browser-extension-update.js"

const directories: Array<string> = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true })
})

const profileWithStoreInstall = (versions: Record<string, ReadonlyArray<string>>): string => {
  const profile = mkdtempSync(join(tmpdir(), "codevisor-chrome-profile-"))
  directories.push(profile)
  for (const [version, files] of Object.entries(versions)) {
    const directory = join(profile, "Extensions", CODEVISOR_BROWSER_EXTENSION_ID, version)
    mkdirSync(directory, { recursive: true })
    for (const file of files) writeFileSync(join(directory, file), "")
  }
  return profile
}

const moved = "http://127.0.0.1:49363"

const loadedFrom = (files: ReadonlyArray<string>) => {
  const directory = mkdtempSync(join(tmpdir(), "codevisor-unpacked-extension-"))
  directories.push(directory)
  for (const file of files) writeFileSync(join(directory, file), "")
  return directory
}
const profileLoading = (path: string, file = "Secure Preferences") => {
  const profile = profileWithStoreInstall({})
  const settings = { [CODEVISOR_BROWSER_EXTENSION_ID]: { location: 4, path } }
  writeFileSync(join(profile, file), JSON.stringify({ extensions: { settings } }))
  return profile
}

describe("extensionNeedsUpdate", () => {
  it("flags a Web Store install that only knows 49361 once the server has moved", () => {
    const old = profileWithStoreInstall({ "0.1.100_0": ["background.js"] })

    expect(extensionNeedsUpdate({ connected: false, relayBaseUrl: moved, profiles: [old] })).toBe(
      true
    )
  })

  it("stays quiet when nothing is actually wrong", () => {
    const old = profileWithStoreInstall({ "0.1.100_0": ["background.js"] })
    const updating = profileWithStoreInstall({
      "0.1.100_0": ["background.js"],
      "0.1.108_0": ["background.js", "relay-candidates.js"]
    })
    const unpacked = profileWithStoreInstall({})
    const missing = join(tmpdir(), "codevisor-no-such-profile")

    for (const inputs of [
      { connected: false, relayBaseUrl: "http://127.0.0.1:49361", profiles: [old] },
      { connected: true, relayBaseUrl: moved, profiles: [old] },
      { connected: false, relayBaseUrl: moved, profiles: [updating] },
      { connected: false, relayBaseUrl: moved, profiles: [unpacked, missing] }
    ]) {
      expect(extensionNeedsUpdate(inputs)).toBe(false)
    }
  })

  it("checks drag-installed copies wherever Chrome loads them from", () => {
    const old = profileLoading(loadedFrom(["background.js"]))
    const current = profileLoading(
      loadedFrom(["background.js", "relay-candidates.js"]),
      "Preferences"
    )
    const relative = profileLoading("clemkifaacpllomplgomnkbeoiindbhl/0.1.107_0")
    const damaged = profileWithStoreInstall({})
    writeFileSync(join(damaged, "Preferences"), "{")

    expect(extensionNeedsUpdate({ connected: false, relayBaseUrl: moved, profiles: [old] })).toBe(
      true
    )
    for (const profile of [current, relative, damaged]) {
      expect(
        extensionNeedsUpdate({ connected: false, relayBaseUrl: moved, profiles: [profile] })
      ).toBe(false)
    }
  })
})
