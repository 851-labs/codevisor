import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished, vi } from "vitest"

import { SCREEN_SHARING_CONFIG_FILE } from "../routes/screen-sharing-vnc.js"
import { runDesktop } from "./desktop-runner.js"

const folderWithAnXvncThatNeverComesUp = (): string => {
  const folder = mkdtempSync(join(tmpdir(), "cv-runner-"))
  onTestFinished(() => rmSync(folder, { recursive: true, force: true }))
  const started = join(folder, "started")
  writeFileSync(join(folder, "Xvnc"), `#!/bin/sh\necho up > "${started}"\nexec sleep 300\n`)
  chmodSync(join(folder, "Xvnc"), 0o755)
  const vnc = { socket: join(folder, "d.sock"), xauthority: join(folder, "d.xauth"), display: 97 }
  writeFileSync(join(folder, SCREEN_SHARING_CONFIG_FILE), JSON.stringify({ vnc }))
  return folder
}

it("ends quietly, with success, when it is stopped while the X server is still starting", async () => {
  const folder = folderWithAnXvncThatNeverComesUp()
  vi.stubEnv("PATH", `${folder}:${process.env["PATH"] ?? ""}`)
  onTestFinished(() => {
    vi.unstubAllEnvs()
  })
  const lines: string[] = []
  const stopRequested = Promise.withResolvers<() => void>()

  const ended = runDesktop(folder, (line) => lines.push(line), stopRequested.resolve)
  const stop = await stopRequested.promise
  stop()

  expect(await ended).toBe(0)
  expect(lines).toEqual([])
})
