import { describe, expect, it } from "vitest"

import { latestMacOSDownloadURL } from "./github-release"

describe("latestMacOSDownloadURL", () => {
  it("points at the Apple silicon disk image on the latest stable release", () => {
    expect(latestMacOSDownloadURL()).toBe(
      "https://github.com/851-labs/codevisor/releases/latest/download/Codevisor-arm64.dmg"
    )
  })
})
