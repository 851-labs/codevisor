import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished } from "vitest"

import { removeSessionConfig, sessionConfigFolders } from "./session-autostart.js"

const runtimeFolder = (): string => {
  const folder = mkdtempSync(join(tmpdir(), "cv-autostart-"))
  onTestFinished(() => rmSync(folder, { recursive: true, force: true }))
  return folder
}

it("puts a folder ahead of the system's that hides the PolicyKit agent from the desktop's autostart", () => {
  const folder = runtimeFolder()
  const ours = join(folder, "codevisor-desktop-xdg")
  expect(sessionConfigFolders(folder, undefined)).toBe(`${ours}:/etc/xdg`)
  expect(readFileSync(join(ours, "autostart", "xfce-polkit.desktop"), "utf8")).toContain(
    "Hidden=true"
  )
})

it("keeps the config folders the account already has, after its own", () => {
  const folder = runtimeFolder()
  expect(sessionConfigFolders(folder, "/etc/xdg/xdg-xfce:/etc/xdg")).toBe(
    `${join(folder, "codevisor-desktop-xdg")}:/etc/xdg/xdg-xfce:/etc/xdg`
  )
  expect(sessionConfigFolders(folder, "")).toBe(`${join(folder, "codevisor-desktop-xdg")}:/etc/xdg`)
})

it("is taken away again when the desktop stops, and only its own folder", () => {
  const folder = runtimeFolder()
  sessionConfigFolders(folder, undefined)
  removeSessionConfig(folder)
  expect(existsSync(join(folder, "codevisor-desktop-xdg"))).toBe(false)
  expect(existsSync(folder)).toBe(true)
})

it("starts from a folder it made itself, so nothing left in that place gets started with the desktop", () => {
  const folder = runtimeFolder()
  const autostart = join(folder, "codevisor-desktop-xdg", "autostart")
  mkdirSync(autostart, { recursive: true })
  writeFileSync(join(autostart, "planted.desktop"), "[Desktop Entry]\nExec=true\n")
  sessionConfigFolders(folder, undefined)
  expect(readdirSync(autostart)).toEqual(["xfce-polkit.desktop"])
})

it("goes without its own folder when it can't make one that is its own", () => {
  const notAFolder = join(runtimeFolder(), "a-file")
  writeFileSync(notAFolder, "")
  expect(sessionConfigFolders(notAFolder, undefined)).toBe("/etc/xdg")
  expect(sessionConfigFolders(notAFolder, "/etc/xdg/xdg-xfce:/etc/xdg")).toBe(
    "/etc/xdg/xdg-xfce:/etc/xdg"
  )
})
