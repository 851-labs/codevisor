import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { makeGitRepo } from "./git-test-support.js"
import { addWorktree } from "./git.js"
import { removeArchivedWorktreeFiles } from "./worktree-archive.js"
import {
  removeWorktreeXcodeArtifacts,
  sweepStaleXcodeArtifacts,
  type XcodeArtifactHost
} from "./xcode-artifacts.js"

const roots: Array<string> = []
afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

const escapeXml = (text: string): string => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;")

const fixture = (root = mkdtempSync(join(tmpdir(), "xcode-artifacts-"))) => {
  roots.push(root)
  const calls: Array<ReadonlyArray<string>> = []
  const host: XcodeArtifactHost = {
    derivedDataRoot: join(root, "DerivedData"),
    simulatorDevicesRoot: join(root, "Devices"),
    simctl: async (args) => {
      calls.push(args)
      // Like simctl: shutting down a device that is not booted fails, and so
      // does everything when CoreSimulatorService is unavailable.
      if (args[0] === "shutdown" || args[1] === "unavailable") throw new Error("simctl failed")
      // Its owner process deleted this one first.
      if (args[1] === "RACED") throw new Error("Invalid device: RACED")
    }
  }
  mkdirSync(host.derivedDataRoot, { recursive: true })
  const derivedData = (name: string, workspacePath?: string): string => {
    const path = join(host.derivedDataRoot, name)
    mkdirSync(path)
    if (workspacePath !== undefined) {
      writeFileSync(
        join(path, "info.plist"),
        `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>LastAccessedDate</key>\n\t<date>2026-09-25T22:44:03Z</date>\n\t<key>WorkspacePath</key>\n\t<string>${escapeXml(workspacePath)}</string>\n</dict>\n</plist>\n`
      )
    }
    return path
  }
  const simulator = (udid: string, marker?: Record<string, unknown> | string): void => {
    mkdirSync(join(host.simulatorDevicesRoot, udid), { recursive: true })
    if (marker === undefined) return
    writeFileSync(
      join(host.simulatorDevicesRoot, udid, "codevisor-owner.json"),
      typeof marker === "string"
        ? marker
        : JSON.stringify({
            format: "codevisor-ios-simulator-v1",
            udid,
            ...marker
          })
    )
  }
  const deleted = (): ReadonlyArray<string> =>
    calls.filter((args) => args[0] === "delete").map((args) => args[1] ?? "")
  return { host, root, derivedData, simulator, deleted }
}

describe("removeWorktreeXcodeArtifacts", () => {
  it("deletes only the removed worktree's DerivedData and marked simulators", async () => {
    const { host, root, derivedData, simulator, deleted } = fixture()
    const salmon = join(root, "codevisor", "project", "salmon & co")
    const ours = derivedData("Codevisor-a", join(salmon, "apps/ios/Codevisor.xcodeproj"))
    // A sibling whose name merely starts with the same characters.
    const prefix = derivedData("Codevisor-b", join(`${salmon}-2`, "apps/ios/Codevisor.xcodeproj"))
    const shared = derivedData("ModuleCache.noindex")
    const unkeyed = derivedData("Unkeyed")
    writeFileSync(join(unkeyed, "info.plist"), "<plist><dict></dict></plist>\n")
    simulator("OWNED", { repoRoot: salmon })
    simulator("OTHER", {
      repoRoot: join(root, "codevisor", "project", "sorbet")
    })
    // Friendly names are never trusted: an unmarked device is left alone.
    simulator("UNMARKED")
    simulator("CORRUPT", "{")
    simulator("NULL", "null")
    simulator("FOREIGN", { repoRoot: salmon, format: "someone-else" })
    simulator("NO-ROOT", { repoRoot: 42 })
    // A marker naming a different device does not claim this one.
    simulator("COPIED", { repoRoot: salmon, udid: "OWNED" })

    await removeWorktreeXcodeArtifacts(salmon, host)

    expect(existsSync(ours)).toBe(false)
    expect(existsSync(prefix)).toBe(true)
    expect(existsSync(shared)).toBe(true)
    expect(existsSync(unkeyed)).toBe(true)
    expect(deleted()).toEqual(["OWNED"])
  })

  it("runs when an archived worktree's files are removed", async () => {
    const { repo, root } = makeGitRepo(true)
    const { host, derivedData, simulator, deleted } = fixture(join(root, "xcode"))
    const path = join(root, "brownie")
    await addWorktree(repo, path, "codevisor/brownie")
    const data = derivedData("Codevisor-brownie", join(path, "apps/ios/Codevisor.xcodeproj"))
    simulator("BROWNIE", { repoRoot: path })
    simulator("RACED", { repoRoot: path })

    const trashed = await removeArchivedWorktreeFiles(repo, path, "codevisor/brownie", {
      trashRoot: join(root, ".trash"),
      worktreeId: "wt-brownie",
      xcode: host
    })
    await trashed.purged

    expect(existsSync(data)).toBe(false)
    expect(deleted()).toEqual(expect.arrayContaining(["BROWNIE", "RACED"]))
  })
})

describe("sweepStaleXcodeArtifacts", () => {
  it("deletes artifacts of vanished worktrees but not the user's own projects", async () => {
    const { host, root, derivedData, simulator, deleted } = fixture()
    const worktrees = join(root, "codevisor")
    const live = join(worktrees, "project", "tamale")
    mkdirSync(join(live, "App.xcodeproj"), { recursive: true })
    const liveData = derivedData("Live", join(live, "App.xcodeproj"))
    const goneData = derivedData("Gone", join(worktrees, "project", "jicama", "App.xcodeproj"))
    // Outside the worktrees root: the user's own project, even if moved away.
    const userData = derivedData("User", join(root, "Projects", "App.xcodeproj"))
    simulator("LIVE", { repoRoot: live })
    simulator("GONE", { repoRoot: join(worktrees, "project", "jicama") })

    await sweepStaleXcodeArtifacts(worktrees, host)

    expect(existsSync(liveData)).toBe(true)
    expect(existsSync(goneData)).toBe(false)
    expect(existsSync(userData)).toBe(true)
    expect(deleted()).toEqual(["GONE", "unavailable"])
  })

  it("still clears unavailable simulators on a machine that never created one", async () => {
    const { host, root, deleted } = fixture()

    await sweepStaleXcodeArtifacts(join(root, "codevisor"), host)

    expect(deleted()).toEqual(["unavailable"])
  })
})
