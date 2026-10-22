import { describe, expect, it } from "vitest"

import { checksumFor, githubCliRelease, gitlabCliRelease } from "./cli-release.js"

const suffixes = (platforms: ReadonlyArray<[NodeJS.Platform, string]>) =>
  platforms.map(([os, arch]) => [
    githubCliRelease.assetSuffix({ os, arch }),
    gitlabCliRelease.assetSuffix({ os, arch })
  ])

describe("CLI release assets", () => {
  it("names each platform's release archive the way gh and glab publish them", () => {
    expect(
      suffixes([
        ["darwin", "arm64"],
        ["darwin", "x64"],
        ["linux", "arm64"],
        ["linux", "x64"],
        ["win32", "x64"],
        ["linux", "ia32"]
      ])
    ).toEqual([
      ["macOS_arm64.zip", "darwin_arm64.tar.gz"],
      ["macOS_amd64.zip", "darwin_amd64.tar.gz"],
      ["linux_arm64.tar.gz", "linux_arm64.tar.gz"],
      ["linux_amd64.tar.gz", "linux_amd64.tar.gz"],
      [undefined, undefined],
      [undefined, undefined]
    ])
  })

  it("reads an archive's checksum from a release checksums file", () => {
    const checksums = "ABC123  gh_1_macOS_arm64.zip\n\ndef456  gh_1_linux_amd64.tar.gz\n"

    expect(checksumFor(checksums, "gh_1_macOS_arm64.zip")).toBe("abc123")
    expect(checksumFor(checksums, "gh_1_linux_amd64.tar.gz")).toBe("def456")
    expect(checksumFor(checksums, "gh_1_linux_arm64.tar.gz")).toBeUndefined()
  })
})
