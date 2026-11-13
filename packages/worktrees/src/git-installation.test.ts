import { describe, expect, it } from "vitest"

import { hasAppleDeveloperTool, locateGit, type GitHost } from "./git-installation.js"

interface FakeMachine {
  readonly platform?: NodeJS.Platform
  readonly executables: ReadonlyArray<string>
  readonly links?: Readonly<Record<string, string>>
  readonly developerDirectory?: string
}

const hostOf = (machine: FakeMachine): GitHost => ({
  platform: machine.platform ?? "darwin",
  isExecutable: (path) => machine.executables.includes(path),
  realPath: (path) => machine.links?.[path] ?? path,
  developerDirectory: () => machine.developerDirectory
})

const commandLineTools = "/Library/Developer/CommandLineTools"
const applePath = "/usr/bin:/bin"

describe("locating Git", () => {
  it("uses Apple's Git when the developer tools behind it are installed", () => {
    const mac = hostOf({
      executables: ["/usr/bin/git", `${commandLineTools}/usr/bin/git`],
      developerDirectory: commandLineTools
    })

    expect(locateGit({ PATH: applePath }, mac)).toEqual({
      state: "ready",
      path: "/usr/bin/git"
    })
  })

  it("treats Apple's Git as missing when no developer tools back it", () => {
    const mac = hostOf({ executables: ["/usr/bin/git"] })

    expect(locateGit({ PATH: applePath }, mac)).toEqual({ state: "missing" })
  })

  it("treats Apple's Git as missing when the developer tools have lost their Git", () => {
    const mac = hostOf({ executables: ["/usr/bin/git"], developerDirectory: commandLineTools })

    expect(locateGit({ PATH: applePath }, mac)).toEqual({ state: "missing" })
  })

  it("skips an unbacked Apple Git for a real one later on the PATH", () => {
    const mac = hostOf({ executables: ["/usr/bin/git", "/opt/conda/bin/git"] })

    expect(locateGit({ PATH: `${applePath}:/opt/conda/bin` }, mac)).toEqual({
      state: "ready",
      path: "/opt/conda/bin/git"
    })
  })

  it("takes the first Git on the PATH when it is not Apple's", () => {
    const mac = hostOf({ executables: ["/opt/homebrew/bin/git", "/usr/bin/git"] })

    expect(locateGit({ PATH: `/opt/homebrew/bin:${applePath}` }, mac)).toEqual({
      state: "ready",
      path: "/opt/homebrew/bin/git"
    })
  })

  it("sees through a link to Apple's Git", () => {
    const mac = hostOf({
      executables: ["/Users/me/bin/git"],
      links: { "/Users/me/bin/git": "/usr/bin/git" }
    })

    expect(locateGit({ PATH: "/Users/me/bin" }, mac)).toEqual({ state: "missing" })
  })

  it("trusts /usr/bin/git off the Mac, where it is never a placeholder", () => {
    const linux = hostOf({ platform: "linux", executables: ["/usr/bin/git"] })

    expect(locateGit({ PATH: applePath }, linux)).toEqual({
      state: "ready",
      path: "/usr/bin/git"
    })
  })

  it("reports Git missing when the PATH has none", () => {
    expect(locateGit({}, hostOf({ platform: "linux", executables: [] }))).toEqual({
      state: "missing"
    })
  })
})

describe("Apple developer tools", () => {
  it("has a tool only when the selected developer directory ships it", () => {
    const xcode = "/Applications/Xcode.app/Contents/Developer"
    const withXcode = hostOf({
      executables: [`${xcode}/usr/bin/simctl`],
      developerDirectory: xcode
    })
    const toolsOnly = hostOf({ executables: [], developerDirectory: commandLineTools })

    expect(hasAppleDeveloperTool("simctl", withXcode)).toBe(true)
    expect(hasAppleDeveloperTool("simctl", toolsOnly)).toBe(false)
    expect(hasAppleDeveloperTool("simctl", hostOf({ executables: [] }))).toBe(false)
  })
})
