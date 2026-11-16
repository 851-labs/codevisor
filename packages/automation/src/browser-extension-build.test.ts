import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { describe, expect, it, onTestFinished } from "vitest"

import {
  bundledExtension,
  describeExtensionError,
  outdatedExtensionNote,
  readExtensionHello,
  stampExtensionBuild
} from "./browser-extension-build.js"

const extensionSource = (files: Record<string, string> = {}): string => {
  const directory = mkdtempSync(join(tmpdir(), "extension-source-"))
  onTestFinished(() => rmSync(directory, { recursive: true, force: true }))
  const contents = {
    "manifest.json": JSON.stringify({ name: "Codevisor", version: "0.2.0" }),
    "extension-build.js": "globalThis.CODEVISOR_EXTENSION_PROTOCOL = 3\n",
    "background.js": "connect()\n",
    "relay-config.js": 'globalThis.CODEVISOR_RELAY = "ws://127.0.0.1:1/"\n',
    ...files
  }
  for (const [name, text] of Object.entries(contents)) writeFileSync(join(directory, name), text)
  return directory
}

const expected = { protocol: 3, build: "0.2.0 (aaaaaaaa)" }
const introduced = (protocol: number, build?: string) => ({
  hello: { protocol, build },
  lackedCommand: false
})

describe("Chrome extension build", () => {
  it("names a build after the extension's own code, not the per-install relay address", () => {
    const first = bundledExtension(extensionSource())
    expect(first.protocol).toBe(3)
    expect(first.build).toMatch(/^0\.2\.0 \([0-9a-f]{8}\)$/)

    const relocated = extensionSource({ "relay-config.js": "somewhere else\n" })
    const edited = extensionSource({ "background.js": "connect(); retry()\n" })
    expect(bundledExtension(relocated).build).toBe(first.build)
    expect(bundledExtension(edited).build).not.toBe(first.build)
  })

  it("stamps the build into a staged copy's manifest and keeps the rest of it", () => {
    const source = extensionSource()
    const staged = extensionSource()
    stampExtensionBuild(staged, source)
    expect(JSON.parse(readFileSync(join(staged, "manifest.json"), "utf8"))).toEqual({
      name: "Codevisor",
      version: "0.2.0",
      version_name: bundledExtension(source).build
    })
  })

  it("reads an introduction and ignores anything malformed", () => {
    expect(readExtensionHello({ protocol: 3, version: "1.2.0", build: null })).toEqual({
      protocol: 3,
      build: undefined
    })
    expect(readExtensionHello({ protocol: 3, build: "0.2.0 (abc)" })?.build).toBe("0.2.0 (abc)")
    expect(readExtensionHello({ protocol: "3" })).toBeUndefined()
    expect(readExtensionHello(undefined)).toBeUndefined()
  })

  it("calls an extension out of date when it lacked a command, speaks an older protocol, or is a stale copy", () => {
    const older = /^The Codevisor Chrome extension is older than this app/
    const quiet = { hello: undefined, lackedCommand: false }
    expect(outdatedExtensionNote({ ...quiet, lackedCommand: true }, expected)).toMatch(older)
    expect(outdatedExtensionNote(introduced(2), expected)).toMatch(older)
    expect(outdatedExtensionNote(introduced(3, "0.2.0 (bbbbbbbb)"), expected)).toMatch(
      /^Chrome is running an unpacked copy of the Codevisor extension from a different version/
    )
  })

  it("accepts an extension from before introductions, the same or a newer protocol, a matching copy, and a store build", () => {
    expect(
      outdatedExtensionNote({ hello: undefined, lackedCommand: false }, expected)
    ).toBeUndefined()
    expect(outdatedExtensionNote(introduced(3), expected)).toBeUndefined()
    expect(outdatedExtensionNote(introduced(4), expected)).toBeUndefined()
    expect(outdatedExtensionNote(introduced(3, expected.build), expected)).toBeUndefined()
    expect(
      outdatedExtensionNote(introduced(1), { ...expected, protocol: undefined })
    ).toBeUndefined()
  })

  it("explains a command the extension doesn't know, and leaves other errors alone", () => {
    expect(describeExtensionError("Unsupported browser command: Target.activateTarget")).toBe(
      "The Codevisor Chrome extension is out of date: it doesn't know Target.activateTarget. Update it at chrome://extensions (turn on Developer mode, then Update), or press its reload button there if it was loaded unpacked."
    )
    expect(describeExtensionError("That tab is not shared with Codevisor")).toBe(
      "That tab is not shared with Codevisor"
    )
  })
})
