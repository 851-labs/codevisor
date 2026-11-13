import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { join } from "node:path"

import type { AgentSessionSummary } from "@codevisor/api"
import { describe, expect, it, onTestFinished } from "vitest"

import { scanSessionFolders } from "./project-recommendations.js"
import { folderAccess, type FolderDecisions } from "./protected-folders.js"

const makeHome = (): string => {
  const home = mkdtempSync(join(process.cwd(), ".protected-folders-"))
  onTestFinished(() => rmSync(home, { force: true, recursive: true }))
  return home
}

const session = (cwd: string): AgentSessionSummary => ({ sessionId: cwd, cwd })

const undecided: FolderDecisions = {}

const scanOnMac = (
  home: string,
  sessions: ReadonlyArray<AgentSessionSummary>,
  decisions: FolderDecisions | undefined
) =>
  scanSessionFolders(sessions, {
    managedWorktreesRoot: join(home, "managed"),
    temporaryDirectory: join(home, "temporary"),
    access: folderAccess(decisions, { platform: "darwin", homeDirectory: home })
  })

describe("protected folders on a Mac", () => {
  it("holds projects in Desktop, Documents, Downloads and other drives without looking at them", () => {
    const home = makeHome()
    const unseen = [
      join(home, "Desktop", "site"),
      join(home, "Documents", "code", "api"),
      join(home, "Downloads", "demo"),
      "/Volumes/Work/app"
    ]

    const scan = scanOnMac(home, unseen.map(session), undecided)

    expect(scan.recommendations).toEqual([])
    expect(scan.held.map((held) => [held.folder.id, held.folder.name, held.project.path])).toEqual([
      ["documents", "Documents", unseen[1]],
      ["volume:Work", "Work", unseen[3]],
      ["downloads", "Downloads", unseen[2]],
      ["desktop", "Desktop", unseen[0]]
    ])
  })

  it("reads a folder the user allowed and stays out of one they declined", () => {
    const home = makeHome()
    const allowed = join(home, "Documents", "api")
    const declined = join(home, "Desktop", "site")
    mkdirSync(allowed, { recursive: true })
    mkdirSync(declined, { recursive: true })

    const scan = scanOnMac(home, [session(allowed), session(declined)], {
      documents: "allowed",
      desktop: "declined"
    })

    expect(scan.recommendations.map((project) => project.path)).toEqual([allowed])
    expect(scan.held).toEqual([])
  })

  it("holds a worktree's repository in Documents without opening the repository", () => {
    const home = makeHome()
    const checkout = join(home, "worktrees", "feature")
    const repository = join(home, "Documents", "api")
    mkdirSync(checkout, { recursive: true })
    writeFileSync(join(checkout, ".git"), `gitdir: ${repository}/.git/worktrees/feature\n`)

    const scan = scanOnMac(home, [session(checkout)], undecided)

    expect(scan.recommendations).toEqual([])
    expect(scan.held.map((held) => held.project.path)).toEqual([repository])
  })

  it("never offers folders that hold other apps' data", () => {
    const home = makeHome()
    const containers = join(home, "Library", "Containers", "com.example.app", "Data", "project")
    const cloud = join(home, "Library", "Mobile Documents", "com~apple~CloudDocs", "project")
    mkdirSync(containers, { recursive: true })
    mkdirSync(cloud, { recursive: true })

    expect(scanOnMac(home, [session(containers), session(cloud)], undecided)).toEqual({
      recommendations: [],
      held: []
    })
  })

  it("leaves installs from before folder decisions reading every folder", () => {
    const home = makeHome()
    const project = join(home, "Documents", "api")
    mkdirSync(project, { recursive: true })

    const scan = scanOnMac(home, [session(project)], undefined)

    expect(scan.recommendations.map((recommendation) => recommendation.path)).toEqual([project])
  })

  it("has no protected folders off the Mac", () => {
    const home = makeHome()
    const project = join(home, "Documents", "api")
    mkdirSync(project, { recursive: true })

    const scan = scanSessionFolders([session(project)], {
      managedWorktreesRoot: join(home, "managed"),
      temporaryDirectory: join(home, "temporary"),
      access: folderAccess({}, { platform: "linux", homeDirectory: home })
    })

    expect(scan.recommendations.map((recommendation) => recommendation.path)).toEqual([project])
  })
})
