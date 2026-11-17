import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { expect, it, onTestFinished } from "vitest"

import { purgeDevelopmentAppState } from "./dev-app-state.ts"

const scratch = async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-app-state-test-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  return root
}

it("removes one worktree's app state and leaves every other app's", async () => {
  const home = await scratch()
  const userCache = await scratch()
  const caches = join(home, "Library/Caches")
  const preferences = join(home, "Library/Preferences")
  await mkdir(join(caches, "com.851labs.Codevisor.Development.aaaaaaaaaa/Chromium-v2"), {
    recursive: true
  })
  await mkdir(join(caches, "com.851labs.Codevisor.Development.iOS.aaaaaaaaaa.macos-screenshots"))
  await mkdir(join(caches, "com.851labs.Codevisor.Development.aaaaaaaaaab"))
  await mkdir(join(caches, "com.851labs.Codevisor.Development"))
  await mkdir(join(caches, "com.851labs.Codevisor"))
  await mkdir(preferences)
  await writeFile(join(preferences, "com.851labs.Codevisor.Development.aaaaaaaaaa.plist"), "")
  await writeFile(join(preferences, "com.851labs.Codevisor.Development.plist"), "")
  await mkdir(join(userCache, "com.851labs.Codevisor.Development.aaaaaaaaaa.chromium.helper"))
  await mkdir(join(userCache, "com.apple.Safari"))
  const commands: Array<string> = []

  await purgeDevelopmentAppState("aaaaaaaaaa", {
    home,
    userDirectories: async () => [userCache],
    run: async (command, args) => commands.push([command, ...args].join(" "))
  })

  expect((await readdir(caches)).toSorted()).toEqual([
    "com.851labs.Codevisor",
    "com.851labs.Codevisor.Development",
    "com.851labs.Codevisor.Development.aaaaaaaaaab"
  ])
  expect(await readdir(preferences)).toEqual(["com.851labs.Codevisor.Development.plist"])
  expect(await readdir(userCache)).toEqual(["com.apple.Safari"])
  expect(commands).toEqual([
    "/usr/bin/defaults delete com.851labs.Codevisor.Development.aaaaaaaaaa",
    "/usr/bin/tccutil reset All com.851labs.Codevisor.Development.aaaaaaaaaa",
    "/usr/bin/security delete-generic-password -s com.851labs.Codevisor.Development.aaaaaaaaaa.browser.safe-storage",
    "/usr/bin/defaults delete com.851labs.Codevisor.Development.iOS.aaaaaaaaaa",
    "/usr/bin/tccutil reset All com.851labs.Codevisor.Development.iOS.aaaaaaaaaa",
    "/usr/bin/security delete-generic-password -s com.851labs.Codevisor.Development.iOS.aaaaaaaaaa.browser.safe-storage"
  ])
})

it("keeps removing files when the system has nothing registered for the app", async () => {
  const home = await scratch()
  const webKit = join(home, "Library/WebKit")
  await mkdir(join(webKit, "com.851labs.Codevisor.Development.aaaaaaaaaa"), { recursive: true })

  await purgeDevelopmentAppState("aaaaaaaaaa", {
    home,
    userDirectories: async () => [],
    run: async () => {
      throw new Error("Domain not found")
    }
  })

  expect(await readdir(webKit)).toEqual([])
})
