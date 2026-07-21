import { describe, expect, it } from "vitest"
import { latestMacOSDownloadURL } from "./github-release"

describe("latestMacOSDownloadURL", () => {
  it("maps each CPU to its stable GitHub release asset", () => {
    expect(latestMacOSDownloadURL("arm64")).toBe(
      "https://github.com/851-labs/codevisor/releases/latest/download/Codevisor-arm64.dmg"
    )
    expect(latestMacOSDownloadURL("x64")).toBe(
      "https://github.com/851-labs/codevisor/releases/latest/download/Codevisor-x64.dmg"
    )
  })
})
