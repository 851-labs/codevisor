import { describe, expect, it } from "vitest"

import { makeOpenCodeLocator } from "./binary.js"

const versions: Record<string, string | undefined> = {
  "/opt/homebrew/bin/opencode": "1.18.31\n",
  "/home/me/.opencode/bin/opencode": "opencode v2.0.24\n",
  "/usr/local/bin/opencode": "opencode v2.1.0\n",
  "/broken/opencode": undefined,
  "/tie/opencode": "opencode v2.0.24"
}

const locate = (candidates: ReadonlyArray<string>) =>
  makeOpenCodeLocator({ candidates: () => candidates, readVersion: (path) => versions[path] })({})

describe("Which OpenCode runs", () => {
  it("runs the newest OpenCode, whatever order PATH lists them in", () => {
    expect(locate(["/opt/homebrew/bin/opencode", "/home/me/.opencode/bin/opencode"])).toBe(
      "/home/me/.opencode/bin/opencode"
    )
    expect(
      locate([
        "/usr/local/bin/opencode",
        "/opt/homebrew/bin/opencode",
        "/home/me/.opencode/bin/opencode"
      ])
    ).toBe("/usr/local/bin/opencode")
    // A tie keeps the one PATH lists first.
    expect(locate(["/home/me/.opencode/bin/opencode", "/tie/opencode"])).toBe(
      "/home/me/.opencode/bin/opencode"
    )
    // The same binary listed twice is one candidate.
    expect(locate(["/opt/homebrew/bin/opencode", "/opt/homebrew/bin/opencode"])).toBe(
      "/opt/homebrew/bin/opencode"
    )
  })

  it("prefers any readable version, and has nothing without a binary", () => {
    expect(locate(["/broken/opencode", "/opt/homebrew/bin/opencode"])).toBe(
      "/opt/homebrew/bin/opencode"
    )
    expect(locate(["/opt/homebrew/bin/opencode", "/broken/opencode"])).toBe(
      "/opt/homebrew/bin/opencode"
    )
    expect(locate(["/broken/opencode"])).toBe("/broken/opencode")
    expect(locate([])).toBeUndefined()
  })
})
