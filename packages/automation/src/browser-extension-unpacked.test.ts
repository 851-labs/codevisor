import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { CODEVISOR_BROWSER_EXTENSION_ID } from "./browser-extension-relay.js"
import { hasUnpackedInstall } from "./browser-extension-unpacked.js"

const directories: Array<string> = []

afterEach(() => {
  for (const directory of directories.splice(0)) rmSync(directory, { recursive: true, force: true })
})

const temporaryDirectory = (prefix: string): string => {
  const directory = mkdtempSync(join(tmpdir(), prefix))
  directories.push(directory)
  return directory
}

const profileWithStoreInstall = (): string => {
  const profile = temporaryDirectory("codevisor-chrome-profile-")
  mkdirSync(join(profile, "Extensions", CODEVISOR_BROWSER_EXTENSION_ID, "0.2.0_0"), {
    recursive: true
  })
  return profile
}

const profileLoading = (path: string, file: string): string => {
  const profile = temporaryDirectory("codevisor-chrome-profile-")
  const settings = { [CODEVISOR_BROWSER_EXTENSION_ID]: { location: 4, path } }
  writeFileSync(join(profile, file), JSON.stringify({ extensions: { settings } }))
  return profile
}

describe("hasUnpackedInstall", () => {
  it("finds drag-installed copies but not Web Store installs", () => {
    const dragged = profileLoading(temporaryDirectory("codevisor-unpacked-"), "Preferences")
    const draggedSecure = profileLoading(
      temporaryDirectory("codevisor-unpacked-"),
      "Secure Preferences"
    )
    const relative = profileLoading(
      `${CODEVISOR_BROWSER_EXTENSION_ID}/0.2.0_0`,
      "Secure Preferences"
    )
    const damaged = profileWithStoreInstall()
    writeFileSync(join(damaged, "Preferences"), "{")

    expect(hasUnpackedInstall([profileWithStoreInstall(), dragged])).toBe(true)
    expect(hasUnpackedInstall([draggedSecure])).toBe(true)
    expect(hasUnpackedInstall([profileWithStoreInstall(), relative, damaged])).toBe(false)
  })
})
